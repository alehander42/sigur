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

