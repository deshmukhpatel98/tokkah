const nav = document.querySelector('.nav');
const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

function onScroll() {
  nav.style.borderBottom = window.scrollY > 24
    ? '1px solid rgba(255,255,255,0.06)'
    : '1px solid transparent';
}
window.addEventListener('scroll', onScroll, { passive: true });
onScroll();

if (!reduce && window.matchMedia('(pointer:fine)').matches) {
  for (const card of document.querySelectorAll('.cards article')) {
    card.addEventListener('pointermove', (e) => {
      const r = card.getBoundingClientRect();
      const x = (e.clientX - r.left) / r.width - 0.5;
      const y = (e.clientY - r.top) / r.height - 0.5;
      card.style.transform = `rotateY(${x * 7}deg) rotateX(${-y * 6}deg) translateY(-3px)`;
    });
    card.addEventListener('pointerleave', () => {
      card.style.transform = '';
    });
  }
  document.querySelector('.cards')?.style.setProperty('perspective', '1200px');
}
