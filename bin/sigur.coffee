#!/usr/bin/env coffee

#
# converts ES5 callback-style code using async library to ~ES7 async/await syntax
# tuned for brains codebase
# implemented conversions
#   callbacks to awaits, including special treatment for mongoose api calls
#   async.watefall to a serie of awaits

falafel = require('falafel')
fs = require('fs')
_ = require('lodash')

asyncifyFile = (sourcePath, outputPath) ->
  fs.readFile(sourcePath, 'utf8', (err, source) ->
    if err
      console.log('ERROR', err)
      return
    a = new AsyncTranslator().translate(source)
    a = String(a).replace(/\n+/g, '\n').replace('}', '}\n')      
    fs.writeFile(outputPath, a))

class AsyncTranslator
  constructor: () -> 
    @indentSize = 2
    @args = [] #contains current function stack arg names

  translate: (source) =>
    @signatureIndex = this.indexSignatures(source)

    falafel(
      source, 
      (node) =>
        if node.type == 'FunctionDeclaration'
          node.update(this.rewriteFunction(node))
        else if node.parent && node.parent.type == 'Program'
          node.update(this.rewriteBlock([node]).code))

  _source: (e) ->
    e.source()

  _indent: (depth) ->
    _.repeat(' ', @indentSize * depth)

  indexSignatures: (source) =>
    index = {}
    falafel(source, (node) ->
      if node.type == 'FunctionDeclaration'
        index[node.id.name] = _.map(node.params, 'name'))
    index

  rewriteFunction: (node) =>
    @args.push(_.map(node.params, 'name'))
    blockResult = this.rewriteBlock(node.body.body, 1)
    @args.pop
    if blockResult.isAsync
     asyncStatus = 'async '
     params = node.params.slice(0, -1)
    else 
      asyncStatus = ''
      params = node.params
    argCode = _.map(params, this._source).join(', ')
    header = "#{asyncStatus}function #{node.id.name}(#{argCode}) {"
    "#{header}\n#{blockResult.code}}\n"

  _isMongoose: (node) =>
    node.type == 'MemberExpression' && node.property.type == 'Identifier' && node.property.name == 'exec'

  _isParallelCallback: (node) =>
    node && node.type == 'Identifier' && node.name == @parallelCallback

  _isCallToArgCallback: (node) =>
    node.type == 'CallExpression' && node.callee.type == 'Identifier' && node.callee.name == _.last(_.last(@args))

  _isCallback: (node) =>
    node && (node.type == 'FunctionExpression' || 
    node.type == 'Identifier' && this._isCallbackName(node.name))


  _isCallbackName: (name) =>
    name.match(/[Cc](all)?[Bb](ack)?/) != null

  _simplifyExpressions: (nodes) ->
    _.map(nodes, (node) ->
        if node.type == 'ExpressionStatement'
          node.expression
        else
          node)

  rewriteBlock: (nodes, depth) =>
    result = {isAsync: false, code: ''}
    results = []
    ind = this._indent(depth)
    nodes = this._simplifyExpressions(nodes)
    for node in nodes
      console.log(ind + 'node', node.source())
      lastArg = _.last(node.arguments)
      if node.type == 'CallExpression' && node.callee.type == 'MemberExpression' &&
              node.callee.object.name == 'async' && node.callee.property.name == 'each' # async.each
        block = node.arguments[1]
        @parallelCallback = block.params[1].name
        blockCode = "\n" + this.rewriteBlock(block.body.body, depth + 1).code
        afterCode = "\n" + this.rewriteBlock(lastArg.body.body, depth).code
        sequence = node.arguments[0].name
        iterator = node.arguments[1].params[0].name

        results.push("#{ind}await #{sequence}.parallelEach(#{iterator} => {#{blockCode}#{ind}});#{afterCode}")
      else if node.type == 'CallExpression' && node.callee.type == 'MemberExpression' &&
              node.callee.object.name == 'async' && node.callee.property.name == 'waterfall' # async watefall
        results.push(this.rewriteWaterfall(node.arguments[0].elements, depth))
      else if node.type == 'CallExpression' && this._isParallelCallback(lastArg)
        argCode = _.map(node.arguments.slice(0, -1), this._source).join('\n')
        results.push("#{ind}#{node.callee.source()}(#{argCode});")
      else if node.type == 'CallExpression' && node.callee.name == @parallelCallback
        2 # TODO raise an exception depending on error model
      else if node.type == 'CallExpression' && this._isCallback(lastArg)
        unless lastArg.type == 'FunctionExpression'
          a = "#{ind}"
        else
          a = "#{ind}var #{_.last(lastArg.params).name} = "
        if this._isMongoose(node.callee)
          callee = node.callee.object
          argCode = ''
        else
          callee = node.callee
          argCode = '(' + _.map(node.arguments.slice(0, -1), this._source).join(', ') + ')'
        results.push("#{a}await #{callee.source()}#{argCode};")
        results.push(this.rewriteBlock(_.last(node.arguments).body.body, depth).code)
        result.isAsync = true
      else if this._isCallToArgCallback(node)
        results.push("#{ind}return#{if lastArg then ' ' + lastArg.source() else ''};")
        result.isAsync = true
      else
        results.push("#{ind}#{node.source()};\n")
    result.code = results.join('\n') + '\n'
    result


  rewriteWaterfall: (calls, depth) =>
    rewrites = []
    ind = this._indent(depth)
    _.each(_.zip(calls.slice(0, -1), calls.slice(1)), ([call, nextCall], j) =>
      f = if j == 0 then '' else @signatureIndex[call.name][0]
      console.log('F', f, j, call.name, @signatureIndex)
      rewrites.push("#{ind}var #{@signatureIndex[nextCall.name][0]} = await #{call.source()}(#{f});"))
    f = @signatureIndex[_.last(calls).name][0]
    rewrites.push("#{ind}await #{_.last(calls).source()}(#{f});")
    rewrites.join('\n') + '\n'

sourcePath = process.argv[2]
outputPath = sourcePath.replace(/\.js$/, '.es7')
asyncifyFile(sourcePath, outputPath)
