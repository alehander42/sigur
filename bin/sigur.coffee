#!/usr/bin/env coffee

#
# converts ES5 callback-style code using async library to ~ES7 async/await syntax
# tuned for brains codebase
# implemented conversions
#   callbacks to awaits, including special treatment for mongoose api calls
#   async.watefall to a serie of awaits

falafel = require('falafel')
fs = require('fs')
escodegen = require('escodegen')
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
    @anonn = 0 #counter for anon waterfall functions
    @asyncs = [] #contains flags for function stack asyncness

  translate: (source) =>
    @signatureIndex = this.indexSignatures(source)

    falafel(
      source,
      (node) =>
        if node.type == 'FunctionDeclaration'
          node.update(this.rewriteFunction(node))
        else if node.parent && node.parent.type == 'Program'
          node.update('\n' + _.map(this.rewriteBlock([node]), this.esGenerate).join('\n')))

  esGenerate: (node) ->
    # uses escodegen with some special settings
    escodegen.generate(node, {
      format: {indent: {style: '  '}},
      comment: true})

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
    @asyncs.push(false)
    blockResult = this.rewriteBlock(node.body.body, 1)
    node.async = @asyncs.pop
    @args.pop
    node.params = node.params.slice(0, -1)
    blockResult = this._cleanReturns(blockResult)
    node.body = {type: 'BlockStatement', body: blockResult}
    this.esGenerate(node)

  _isMongoose: (node) =>
    node.type == 'MemberExpression' && node.property.type == 'Identifier' && node.property.name == 'exec'

  _cleanReturns: (block) ->
    if block.length == 0
      []
    else if block.length == 1
      if block[0].type == 'ReturnStatement' && block[0].argument == null
        []
      else
        block
    else
      a = block[block.length - 2]
      last = block[block.length - 1]
      if last.type == 'ReturnStatement' && last.argument && last.argument.type == 'Identifier' &&
         a.type == 'VariableDeclaration' && a.declarations[0].id.type == 'Identifier' && a.declarations[0].id.name == last.argument.name
        block.slice(0, -2).concat({type: 'ReturnStatement', argument: a.declarations[0].init})
      else if last.type == 'ReturnStatement' && last.argument == null
        block.slice(0, -1)
      else
        block

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
    _.reduce(nodes, ((results, node) =>
      results.concat(this._rewriteLine(node, depth))), [])

  _ensureExpression: (t) ->
    if t.type == 'ExpressionStatement' || !_.contains(t.type, 'Expression')
      t
    else
      {type: 'ExpressionStatement', expression: t}

  _isAsyncMethodCall: (node, method) ->
    node.callee.type == 'MemberExpression' && node.callee.object.name == 'async' &&
      node.callee.property.name == method

  _rewriteLine: (node, depth) =>
    if node.type == 'CallExpression'
      lastArg = _.last(node.arguments)
    switch
      when node.type == 'ExpressionStatement'
        s = this._rewriteLine(node.expression)
        unless Array.isArray(s)
          s = [s]
        _.map(s, this._ensureExpression)
      when node.type == 'BlockStatement'
        {type: 'BlockStatement', body: _.map(node.body, (l) -> this._rewriteLine(this._rewriteLine, depth))}
      when node.type == 'Identifier' && node.callee.name == @parallelCallback
        [] # TODO raise an exception depending on error model
      when node.type != 'CallExpression'
        node
      when this._isAsyncMethodCall(node, 'each') # async.each
        block = node.arguments[1]
        @parallelCallback = block.params[1].name
        block.body.body = this.rewriteBlock(block.body.body, depth + 1)
        if lastArg.type == 'FunctionExpression'
          afterCode = this.rewriteBlock(lastArg.body.body, depth)
        else if lastArg.type == 'Identifier' && lastArg.name == _.last(_.last(@args))
          afterCode = [{type: 'ReturnStatement', argument: null}]
        else
          afterCode = [this._rewriteLine(lastArg)]
        sequence = node.arguments[0].name
        iterator = node.arguments[1].params[0].name

        @asyncs[@asyncs.length - 1] = true
        [{
          type: 'AwaitExpression',
          argument: {
            type: 'CallExpression',
            callee: {
              type: 'MemberExpression',
              object: {type: 'Identifier', name: sequence},
              property: {type: 'Identifier', name: 'parallelEach'}
            },
            arguments: [
              {
                type: 'ArrowFunctionExpression',
                id: null,
                body: block.body,
                params: [{type: 'Identifier', name: iterator}]
              }
            ]
          }}].concat(afterCode)
      when this._isAsyncMethodCall(node, 'waterfall') # async waterfall
        this.rewriteWaterfall(node.arguments[0].elements, node.arguments[1], depth)
      when this._isAsyncMethodCall(node, 'series') # async series
        this.rewriteSeries(node.arguments[0].elements, node.arguments[1], depth)
      when this._isParallelCallback(lastArg)
        node.arguments = node.arguments.slice(0, -1)
        node
      when this._isCallback(lastArg)

        if this._isMongoose(node.callee)
          node = node.callee.object
          node.arguments = []
        else
          node.arguments = node.arguments.slice(0, -1)

        @asyncs[@asyncs.length - 1] = true
        await = {type: 'AwaitExpression', argument: node}
        expression = unless lastArg.type == 'FunctionExpression'
          await
        else
          this._variableAssignment(_.last(lastArg.params).name, await)
        [expression].concat(this.rewriteBlock(lastArg.body.body, depth))


      when this._isCallToArgCallback(node)
        @asyncs[@asyncs.length - 1] = true
        {type: 'ReturnStatement', argument: if lastArg then lastArg else null}
      else
        node

  _variableAssignment: (name, init) ->
    type: 'VariableDeclaration'
    kind: 'let'
    declarations: [
      type: 'VariableDeclarator'
      id: {type: 'Identifier', name: name}
      init: init]

  _rewriteWaterfallCall: (call) =>
    if call.type == 'Identifier'
      {name: call.name, source: {type: 'CallExpression', callee: call, arguments: []}}
    else if call.type == 'CallExpression' && call.callee.type == 'MemberExpression' &&
            call.callee.object.type == 'Identifier' && call.callee.object.name == 'async' &&
            call.callee.property.name == 'apply'
      call.callee = call.arguments[0]
      call.arguments = call.arguments.slice(1)
      {name: call.arguments[0].name, source: call}
    else if call.type == 'FunctionExpression'
      @signatureIndex[String(@anonn)] = _.map(call.params, 'name')
      @anonn += 1
      {name: String(@anonn - 1), source: {type: 'CallExpression', callee: call, arguments: []}}
    else
      throw "2789"

  rewriteWaterfall: (calls, callback, depth) =>
    rewrites = []
    ind = this._indent(depth)
    calls = _.map(calls, this._rewriteWaterfallCall)
    _.each(_.zip(calls.slice(0, -1), calls.slice(1)), ([call, nextCall], j) =>
      f = if j == 0 then [] else {type: 'Identifier', name: @signatureIndex[call.name][0]}
      # console.log('F', f, j, call.name, @signatureIndex)
      call.source.arguments = call.source.arguments.concat(f)
      rewrites.push(this._variableAssignment(@signatureIndex[nextCall.name][0]),
                    {type: 'AwaitExpression', argument: call.source}))
    call = _.last(calls)
    f = {type: 'Identifier', name: @signatureIndex[call.name][0]}
    call.source.arguments = call.source.arguments.concat(f)
    rewrites.push({type: 'AwaitExpression', argument: call.source})
    if callback && callback.type == 'FunctionExpression' && callback.body.body.length == 1 && callback.body.body[0].type == 'IfStatement'
      test = callback.body.body[0].test
      if test.type == 'Identifier' && test.name == callback.params[0].name
        type: 'TryStatement'
        block: {type: 'BlockStatement', body: rewrites}
        handler:
          type: 'CatchClause'
          param: {type: 'Identifier', name: callback.params[0].name}
          body: callback.body.body[0].consequent
        finalizer: null

      else
        rewrites
    else
      rewrites

  _refactorSerie: (func) =>
    @args.push(_.map(func.params, 'name'))
    body = this._cleanReturns(this.rewriteBlock(func.body.body, 0))
    @args.pop
    if body.length == 1 && body[0].type == 'ReturnStatement'
      body[0].argument
    else
      func.body.body = body
      func.params = []

      type: 'AwaitExpression'
      argument:
        type: 'CallExpression'
        callee: func
        arguments: []



  rewriteSeries: (functions, endCallback) =>
    refactored = _.map(functions, this._refactorSerie)
    if endCallback
      list = {type: 'ArrayExpression', elements: refactored}
      assignment = this._variableAssignment(endCallback.params[1].name, list)
      body = this.rewriteBlock(endCallback.body.body, 0)
      [assignment].concat(body)
    else
      refactored



sourcePath = process.argv[2]
outputPath = sourcePath.replace(/\.js$/, '.es7')
asyncifyFile(sourcePath, outputPath)
