function normaliseBox([x, y, width, height], imageWidth, imageHeight) {
  if (![x, y, width, height, imageWidth, imageHeight].every(Number.isFinite) ||
      imageWidth <= 0 || imageHeight <= 0 || width <= 0 || height <= 0) return null;
  const left = Math.max(0, Math.min(imageWidth, x));
  const top = Math.max(0, Math.min(imageHeight, y));
  const right = Math.max(0, Math.min(imageWidth, x + width));
  const bottom = Math.max(0, Math.min(imageHeight, y + height));
  if (right <= left || bottom <= top) return null;
  return [(left + right) / 2 / imageWidth, (top + bottom) / 2 / imageHeight,
    (right - left) / imageWidth, (bottom - top) / imageHeight];
}

function boxFitsImage(x, y, width, height) {
  const tolerance = 0.00001; // five-decimal YOLO serialization
  return [x, y, width, height].every(Number.isFinite) &&
    x - width / 2 >= -tolerance && y - height / 2 >= -tolerance &&
    x + width / 2 <= 1 + tolerance && y + height / 2 <= 1 + tolerance;
}

module.exports = { normaliseBox, boxFitsImage };
