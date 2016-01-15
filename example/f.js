async.series([
    function (callback) {
        E.find().exec(function (err, b0) {
            callback(b0);
        });
    },
    function (callback) {
        E1.find().select('s').exec(function (err, b1) {
            callback(b1);
        });

    }
  ],
  function (err, results) {
    console.log(results);
});
