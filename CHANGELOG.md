## [0.3.3](https://github.com/rudironsoni/macos-offload/compare/v0.3.2...v0.3.3) (2026-07-26)


### Features

* rename the project and executable to macos-offload ([55fe767](https://github.com/rudironsoni/macos-offload/commit/55fe767743a4fa5bd5f2ee3129639ad3f3c3c9f4))


## [0.3.2](https://github.com/rudironsoni/macos-offload/compare/v0.3.1...v0.3.2) (2026-07-25)


### Bug Fixes

* enforce simulator command timeouts ([f86af09](https://github.com/rudironsoni/macos-offload/commit/f86af09625f2c068ae0f586c1dbc27249bb009a6))
* make simulator mounts self-reconciling ([97ec2c0](https://github.com/rudironsoni/macos-offload/commit/97ec2c064c52d026b7aa2713dc540c36e71c2dee))
* make subprocess output capture portable ([39191e4](https://github.com/rudironsoni/macos-offload/commit/39191e42a460bb1ad2626a196220bdf1938ae960))
* prevent subprocess pipe inheritance ([30959ac](https://github.com/rudironsoni/macos-offload/commit/30959acf6434ef776298373d4f161f523c580cac))
* route derived data through mounted apple path ([6e2c5ab](https://github.com/rudironsoni/macos-offload/commit/6e2c5ab401756d9e588b65420dddc07442e2d5d1))

## [0.3.1](https://github.com/rudironsoni/macos-offload/compare/v0.3.0...v0.3.1) (2026-07-05)


### Bug Fixes

* keep source release builds clean ([63fdb41](https://github.com/rudironsoni/macos-offload/commit/63fdb41f605da640a445058856f2e907de5f4971))

## [0.3.0](https://github.com/rudironsoni/macos-offload/compare/v0.2.0...v0.3.0) (2026-07-05)


### Features

* add xcodes compatibility profile ([b57c225](https://github.com/rudironsoni/macos-offload/commit/b57c225d54f05226cca34641605a1f1b6d608c23))


### Bug Fixes

* **cli:** show simulator command help ([878c98e](https://github.com/rudironsoni/macos-offload/commit/878c98e0f13a2c4fc1ded31d7ef3647ebba641dc))
* make mount logs readable ([c79f828](https://github.com/rudironsoni/macos-offload/commit/c79f828d572805003b2f2836a9a522f8b94a4cfb))
* verify simulator usability on external storage ([d919a15](https://github.com/rudironsoni/macos-offload/commit/d919a158adb76de68ea103b48f451db18741d608))

## [0.2.0](https://github.com/rudironsoni/macos-offload/compare/v0.1.0...v0.2.0) (2026-07-03)


### Features

* add native certification command ([61d332d](https://github.com/rudironsoni/macos-offload/commit/61d332d9b56c393e6ebdb11d3d70a6d5bac5e444))
* add native transparent storage mode ([7f6c857](https://github.com/rudironsoni/macos-offload/commit/7f6c8571423c0f09d2790df62bdb0bf8f3ac7db9))


### Bug Fixes

* harden CoreSimulator mount management ([2dde021](https://github.com/rudironsoni/macos-offload/commit/2dde021669d8fe05e48b9d98251ead0f54c74b36))
* harden native storage verification ([5ca1b2b](https://github.com/rudironsoni/macos-offload/commit/5ca1b2bf9f91727cde257227bde37008b7111443))
* make native dry-runs fail closed ([cdf44e2](https://github.com/rudironsoni/macos-offload/commit/cdf44e2347c6b7bd322d14c7414abbd9840d30cd))
* make simulator open idempotent ([bc3090c](https://github.com/rudironsoni/macos-offload/commit/bc3090c090bbe611e0f30b1019fa072cc54c92d8))
* normalize cli smoke temp paths ([e35c87e](https://github.com/rudironsoni/macos-offload/commit/e35c87e2a142ad284aa490b81708f010c86cc5b5))
* reject native wrong-backend mounts ([56f3656](https://github.com/rudironsoni/macos-offload/commit/56f365600c644fa1633a4936511d6175ad2c16c5))

## 0.1.0 (2026-07-02)


### Features

* add launchd and daemon install aliases ([71c984f](https://github.com/rudironsoni/macos-offload/commit/71c984f47fae75defa7948f3e4a26444c664a4df))
* scaffold xcode offload cli ([978cc84](https://github.com/rudironsoni/macos-offload/commit/978cc84f9a38b67cd2f97ba3441b99a85bff5e4f))


### Bug Fixes

* add launchd hooks without machine defaults ([5fffcd4](https://github.com/rudironsoni/macos-offload/commit/5fffcd40f2398b33c7de740ae2cd4ca31b4b3557))
* add strict doctor and repair checks ([b70d207](https://github.com/rudironsoni/macos-offload/commit/b70d2070093d859fd0bcfab47ab274f877f69707))
* create privileged launchd target directories ([c9f5ffd](https://github.com/rudironsoni/macos-offload/commit/c9f5ffdbc0c41d7f60d2bde66ed25a5a3eac2bed))
* scope repair and preflight system launchd ([dc8fe95](https://github.com/rudironsoni/macos-offload/commit/dc8fe9538b71b5a2baed632ad314b21663803d54))
* use project release tag for build metadata ([7b2902a](https://github.com/rudironsoni/macos-offload/commit/7b2902ad1e6a2e3f0fa9d6762fbb2214f1237d3f))
* verify release checksums from artifact directory ([c1c1f1c](https://github.com/rudironsoni/macos-offload/commit/c1c1f1c482160e3f812fd8a0cf6c77fa7a2578d9))
* write portable release checksums ([84261ae](https://github.com/rudironsoni/macos-offload/commit/84261aef35d306242dbed181883898f3a19dc4f9))

## Unreleased

- Add CI, release automation, changelog generation, and build metadata plumbing.
- Add strict doctor checks for sparsebundle readability, APFS filesystems, cache
  provenance, plist linting, and launchd last exit status.
- Add repair command to compose init, mount, launchd, and optional shim actions.
- Add repair scope and privilege preflight so non-root repair can target user
  launchd assets without partially attempting system launchd installation.
