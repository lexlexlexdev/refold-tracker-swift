"use strict";

const { open, showHUD } = require("@raycast/api");

module.exports = async function toggleRefoldTracking() {
  await open("refoldtracker://toggle");
  await showHUD("Pause / resume requested");
};
