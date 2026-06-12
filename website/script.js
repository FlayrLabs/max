// Year
document.getElementById("year").textContent = new Date().getFullYear();

// Nav frost on scroll
const nav = document.getElementById("nav");
const onScroll = () => nav.classList.toggle("scrolled", window.scrollY > 24);
onScroll();
window.addEventListener("scroll", onScroll, { passive: true });

// Scroll reveal (staggered groups stay in document order)
const io = new IntersectionObserver(
  (entries) => {
    for (const e of entries) {
      if (e.isIntersecting) {
        e.target.classList.add("in");
        io.unobserve(e.target);
      }
    }
  },
  { threshold: 0.16, rootMargin: "0px 0px -8% 0px" }
);
document.querySelectorAll(".reveal").forEach((el) => io.observe(el));

// Cursor-tracking glow on feature cards
document.querySelectorAll(".card").forEach((card) => {
  card.addEventListener("pointermove", (ev) => {
    const r = card.getBoundingClientRect();
    card.style.setProperty("--mx", `${ev.clientX - r.left}px`);
    card.style.setProperty("--my", `${ev.clientY - r.top}px`);
  });
});

// Demo videos — autoplay (muted) when scrolled into view, pause when out of view.
function autoplayOnScroll(id) {
  const v = document.getElementById(id);
  if (!v) return;
  const o = new IntersectionObserver(
    (entries) => {
      for (const e of entries) {
        if (e.isIntersecting) v.play().catch(() => {});
        else v.pause();
      }
    },
    { threshold: 0.35 }
  );
  o.observe(v);
}
autoplayOnScroll("demo");
autoplayOnScroll("remoteVideo");

// Subtle parallax on the hero glow
const glow = document.querySelector(".hero-glow");
if (glow && window.matchMedia("(pointer:fine)").matches) {
  window.addEventListener("pointermove", (e) => {
    const x = (e.clientX / window.innerWidth - 0.5) * 24;
    const y = (e.clientY / window.innerHeight - 0.5) * 24;
    glow.style.transform = `translateX(-50%) translate(${x}px, ${y}px)`;
  }, { passive: true });
}
