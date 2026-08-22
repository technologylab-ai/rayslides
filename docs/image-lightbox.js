(() => {
  const images = Array.from(document.querySelectorAll("main .shot img"));
  if (
    images.length === 0 ||
    typeof HTMLDialogElement === "undefined" ||
    typeof HTMLDialogElement.prototype.showModal !== "function"
  ) return;

  const dialog = document.createElement("dialog");
  dialog.className = "image-lightbox";
  dialog.setAttribute("aria-label", "Enlarged documentation image");

  const enlargedImage = document.createElement("img");
  enlargedImage.className = "image-lightbox-image";

  const closeButton = document.createElement("button");
  closeButton.className = "image-lightbox-close";
  closeButton.type = "button";
  closeButton.setAttribute("aria-label", "Close enlarged image");
  closeButton.textContent = "×";

  dialog.append(enlargedImage, closeButton);
  document.body.append(dialog);

  let opener = null;

  function openImage(image) {
    if (dialog.open) return;
    opener = image;
    enlargedImage.src = image.currentSrc || image.src;
    enlargedImage.alt = image.alt;
    document.documentElement.classList.add("image-lightbox-open");
    dialog.showModal();
    closeButton.focus();
  }

  function closeImage() {
    if (dialog.open) dialog.close();
  }

  for (const image of images) {
    image.classList.add("zoomable-image");
    image.tabIndex = 0;
    image.setAttribute("role", "button");
    image.setAttribute("aria-haspopup", "dialog");
    image.setAttribute("aria-label", `Enlarge image: ${image.alt}`);
    image.addEventListener("click", () => openImage(image));
    image.addEventListener("keydown", (event) => {
      if (event.key !== "Enter" && event.key !== " ") return;
      event.preventDefault();
      openImage(image);
    });
  }

  closeButton.addEventListener("click", closeImage);
  document.addEventListener("keydown", (event) => {
    if (event.key !== "Escape" || !dialog.open) return;
    event.preventDefault();
    closeImage();
  });
  dialog.addEventListener("click", (event) => {
    if (event.target === dialog) closeImage();
  });
  dialog.addEventListener("close", () => {
    enlargedImage.removeAttribute("src");
    document.documentElement.classList.remove("image-lightbox-open");
    opener?.focus();
    opener = null;
  });
})();
