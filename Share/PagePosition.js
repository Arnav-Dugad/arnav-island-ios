// Safari runs this before the share sheet opens: the page's address, title and how far down it's scrolled, so "Continue on
// your PC" opens it there at the same place.
var PagePosition = function () {};
PagePosition.prototype = {
  run: function (args) {
    var h = document.documentElement.scrollHeight - window.innerHeight;
    args.completionFunction({ url: document.location.href, title: document.title, scroll: h > 0 ? window.scrollY / h : 0 });
  },
  finalize: function () {}
};
var ExtensionPreprocessingJS = new PagePosition();
