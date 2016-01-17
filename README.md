## sigur

Sometimes callbacks can be quite annoying and frustrating. Everybody loves the `async`/`await` syntax popularized by C#, now Python has it, but JS would probably have it only in ES7.

That's a simple library to help with that problem for ES5 code.

## what does it do

It can convert js code between vanilla ES5 callbacks code and a representation using ES7 `async/await` syntax.

It can be useful for visualizing how existing callbacks-style code would look with `async/await`-like syntax

It's tuned for the codebase I am currently working with, so there are some pretty special cases/assumptions in it

## progress

- [x] converts nested callbacks to series of `await`-s in `async`-annotated functions
- [x] converts some cases of `async.each` to `await parallelEach(iterator => code)` code
- [x] converts `async.waterfall` to series of `await` assignments
- [x] converts `async.series` to series of `await` or to `var <name> = [await <expr1>, await .. ];`
- [ ] converts `async.eachSeries` to `for(let )` with `await` expressions 
- [x] converts one-expression functions in `async.series` and `async.waterfall` to just `await` expressions
- [x] detect error handling and support error handling conversion from error callbacks to `try/catch` blocks
- [x] support multiple assignment for callbacks passing several parameters

```javascript
function l(callback) {
    Person.find().exec(function (e, q) {
        callback(null, q);
    });
}

function cosn(q, callback) {
    callback([2]);
}

function loop(qs, callback) {
    async.each(qs, function (q, cb) {
        Person.generateStuff(q, cb);
    }, function (err) {
        console.debug('z');
        callback();
    });
}

async.waterfall([
    l,
    cosn,
    loop
]);
```

is converted to

```javascript
async function l() {
  var q = await Person.find();
  return q;
}

async function cosn(q) {
  return [2];
}
async function loop(qs) {
  await qs.parallelEach(q => {
    Person.generateStuff(q);
  });
  console.debug('z');
  return;
}
var q = await l();
var qs = await cosn(q);
await loop(qs);
```

##usage

```bash
bin/sigur filename.js # saves output to filename.es7
```

##convert back?

using acorn-es7plugin it's possible to write a script that translates
back from the `async/await` output to equivalent to the original callback-based code

if that happens and one feels experimental enough, the usual workflow could be:

* open the file in a `async/await` mode (converted in the background by `sigur`)
* do your changes 
* `sigur` converts it back to callback-based ES5 

## technologies

`falafel` for ast rewriting, based on
`acorn` for analyzing and parsing ast
