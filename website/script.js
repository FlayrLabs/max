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

// Demo video — only wire playback if a source actually loads.
const video = document.getElementById("demo");
const placeholder = document.getElementById("demoPlaceholder");
const playBtn = document.getElementById("playBtn");

function startDemo() {
  if (!video) return;
  video.play().then(() => {
    placeholder.style.opacity = "0";
    placeholder.style.pointerEvents = "none";
  }).catch(() => { /* no source yet — leave the placeholder */ });
}
playBtn?.addEventListener("click", startDemo);

// Remote demo — autoplay (muted) when scrolled into view, pause when out of view.
const remoteVideo = document.getElementById("remoteVideo");
if (remoteVideo) {
  const rio = new IntersectionObserver(
    (entries) => {
      for (const e of entries) {
        if (e.isIntersecting) remoteVideo.play().catch(() => {});
        else remoteVideo.pause();
      }
    },
    { threshold: 0.35 }
  );
  rio.observe(remoteVideo);
}

// Subtle parallax on the hero glow
const glow = document.querySelector(".hero-glow");
if (glow && window.matchMedia("(pointer:fine)").matches) {
  window.addEventListener("pointermove", (e) => {
    const x = (e.clientX / window.innerWidth - 0.5) * 24;
    const y = (e.clientY / window.innerHeight - 0.5) * 24;
    glow.style.transform = `translateX(-50%) translate(${x}px, ${y}px)`;
  }, { passive: true });
}
