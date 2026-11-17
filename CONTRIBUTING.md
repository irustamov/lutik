# Contributing to Lutik

Thanks for your interest. Bug reports, ideas and fixes are welcome.

## Issues

Open an issue for bugs, feature requests and questions. Please use the forms: they ask for the Lutik version, your platform and the archive format, which is most of what is needed to reproduce a problem. Do not attach archives that contain private data. For security problems, do not open an issue: see [SECURITY.md](SECURITY.md).

## How this repository works

This repository is a published export of a private development repository. Development happens there, and each release is exported here as one commit. Pull requests are welcome, but they cannot be merged on GitHub: a change merged here would be overwritten by the next export. Instead, an accepted pull request is applied by hand to the private repository and arrives here with the next export. The pull request is then closed with a note saying so. If you would like to be credited, say so in the pull request and you will be named in the release notes.

For anything larger than a small fix, please open an issue first so we can agree on the approach before you spend time on it.

## Build and test

You need a recent Xcode (26 or later) and [XcodeGen](https://github.com/yonaskolb/XcodeGen). See the README for the full steps.

```sh
brew install xcodegen
xcodegen generate
open Kernir.xcodeproj
```

`Kernir` is the code name of the project; the app is called Lutik. The archive engine is a Swift package, and its tests run without Xcode:

```sh
cd Packages/KernirCore && swift test
```

Please run these tests before you open a pull request, and add a test for a behavior change where you can. The UI follows [PRODUCT.md](PRODUCT.md): stock Apple components only, no custom controls, colors or fonts.

## License

Lutik is released under the [MIT License](LICENSE). By submitting a contribution you agree that it is licensed under the same terms.

## Conduct and security

Everyone taking part is expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md). Report vulnerabilities as described in [SECURITY.md](SECURITY.md).
