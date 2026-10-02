# 4B staging step

`installer/stage.lua` is the first installer step allowed to write files.

It deliberately does not install AtlasOS into its live paths. Instead it:

1. downloads the selected channel file;
2. downloads and validates the referenced manifest;
3. rejects unsafe package paths such as `..` traversal;
4. creates a disposable staging directory under `/.atlas-installer/staging/`;
5. stores snapshots of the channel and manifest used for the operation;
6. downloads each package file into a staged `payload/` tree;
7. writes each download through a `.part` file before renaming it into place.

For the current test package, `/atlasos/boot.lua` therefore becomes:

```text
/.atlas-installer/staging/atlasos-ship/0.0.0-test.1/payload/atlasos/boot.lua
```

The live `/atlasos/boot.lua` is not touched.

This step intentionally does not perform SHA-256 verification yet. The next package-manager step should add integrity metadata to the manifest and verify every staged file before any installation transaction is permitted.
