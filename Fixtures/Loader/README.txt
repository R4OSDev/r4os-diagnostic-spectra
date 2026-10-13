LoaderDiag Runtime Fixtures
===========================

These 14 artifacts are module-local test resources for LOADERD.R4X. They are
not standalone product components and do not receive separate repositories.

The normal LoaderDiag build creates:

- EXTMATH and eight resolver or Runtime-R4L fixtures;
- BADSTART as an invalid R4XStart container;
- LSTRX, LSTRL, LSTRD, and LSTRP as large loader stress containers.

The manifests under Manifests define targets and IMAGE_SCOPE. Fixtures use
deterministic payloads from Fixtures/build.zig and the pinned R4M021 binary
fixtures supplied by the SDK.

0.81.19: LSTRX 0.1.3 explicitly declares runtime.parallel=owned-v1 in both
its manifest and the raw fixture producer. The old kernel pathname exception
is removed; fixture code/payload and the EXTMATH contract are unchanged.
