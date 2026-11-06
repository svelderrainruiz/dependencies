# NIPM Feed

This branch hosts an NI Package Manager (NIPM) feed for packages published
by this repository, served via GitHub Pages.

Register it in a consuming repo's `vipm.toml`:

```toml
[nipm.feeds]
lba-plugins-dependencies = "https://svelderrainruiz.github.io/dependencies/feed/"

[nipm.dependencies]
lbap-dependencies-sd = "<version>"
```

The `feed/` directory is maintained by this repository's CI
(`.github/workflows/build-lvlibp-candidate.yml`, `publish-nipkg-feed` job) --
do not edit it by hand.
