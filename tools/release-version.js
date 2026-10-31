"use strict";

module.exports = function validateReleaseTag(app, environment) {
  const env = environment || process.env;
  if (env.GITHUB_REF_TYPE === "tag" && env.GITHUB_REF_NAME !== `v${app.version}`) {
    throw new Error(`Release tag ${env.GITHUB_REF_NAME} does not match app version v${app.version}`);
  }
};
