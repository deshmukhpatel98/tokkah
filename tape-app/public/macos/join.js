// Split out of join.html because the CSP is script-src 'self' -- an inline
// <script> is silently blocked, which cost a release once already.
(function () {
  var q = new URLSearchParams(location.search);
  var room = (q.get('room') || '').trim();
  // The room name is displayed, so it is set as TEXT and never as HTML. It arrives
  // from a URL somebody else wrote.
  var el = document.getElementById('room');
  if (room && /^[A-Za-z0-9_-]{1,64}$/.test(room)) {
    el.textContent = room;
    document.title = 'Join "' + room + '" on Tokkah';
  } else {
    el.textContent = 'ask them for the room name';
    el.style.fontSize = '18px';
    el.style.color = '#8b93a3';
  }
  document.getElementById('copy').addEventListener('click', function (e) {
    navigator.clipboard.writeText(document.getElementById('inst').textContent).then(function () {
      e.target.textContent = 'Copied';
      setTimeout(function () { e.target.textContent = 'Copy this line'; }, 1600);
    });
  });
})();
