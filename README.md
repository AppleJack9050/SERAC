SERAC
=====

**S**IFT **E**fficient **R**eduction and **A**ccelerated **C**orrespondence: a fused
descriptor matcher for COLMAP.

COLMAP's GPU matcher builds a full similarity matrix for every image pair, then
discards almost all of it, since only the best and second-best score in each row
feed the ratio test. SERAC removes the matrix. The kernel keeps the top two
scores in registers as it goes, so it writes two numbers per row instead of one
per candidate. The rewrite is exact: the match lists are byte-for-byte identical
to the reference implementation's, so nothing is traded for speed.

Two results follow, and they point in opposite directions. Both are reported
here.

- **The stage result is positive.** Matching is 1.28x faster (95% CI
  [1.26, 1.31], n = 10, p < 1e-15), peak matcher memory falls from 1546 to
  700 MiB, and reconstruction statistics move no more than a same-binary rerun
  of the reference moves them on its own.
- **The end-to-end result is negative.** Matching is only 12.1% of total
  runtime in the configuration measured, so even an infinitely fast matcher
  yields at most 1.14x. The 91 s saved is a third of one standard deviation of
  the mapping stage, which SERAC never touches, and therefore below what this
  experiment can resolve.

Measured on Blackwell (RTX 5090, sm_120) against a 589 image survey at
4000x3000, matched exhaustively over all 173,166 pairs.


What is in this repository
--------------------------

This is a patch overlay, not a COLMAP fork. It carries no COLMAP source. The
upstream tree is fetched at a pinned commit and the series below is applied to
it, which is the whole of SERAC's contribution: 8 files, +266 / -142 lines.

```
patches/
  0000-mvs-patchmatch-memory.patch        baseline, in BOTH A/B arms
  0001-dp4a-descriptor-inner-product.patch  \
  0002-fused-row-reduction.patch            |  what the paper measures
  0003-wider-tiles.patch                    |  4 files, +181 / -121
  0004-tie-break-note.patch               /
scripts/
  build.sh          fetch COLMAP, apply, configure, build
  verify-dp4a.sh    confirm DP4A is live in the shipped SASS
paper/      the manuscript these numbers come from
```

The split matters for reading the results. Patch `0000` reduces PatchMatch
dense-stereo memory and works around an NVCC miscompilation on Blackwell; it is
applied to the reference build *and* the SERAC build, so it cancels out of every
comparison below and the paper does not evaluate it. Patches `0001` through
`0004` are the SIFT matcher work, and they are the only difference between the
two arms.

Upstream is pinned at `e8c01c78` ("Fix pycolmap.Database() abort on garbage
collection", 2026-05-26). The series has been verified to reproduce the measured
tree exactly: applied in order to a clean checkout of that commit, all eight
resulting files are byte-for-byte identical to the builds that produced every
number below.


Quick start
-----------

Requires CUDA, CMake, and a compiler COLMAP supports.

```
git clone https://github.com/AppleJack9050/SERAC.git
cd SERAC
scripts/build.sh
```

That clones COLMAP into `build/colmap`, checks out the pinned upstream commit,
applies the full series, and builds with `CUDA_ENABLED=ON` and native
architecture.

To build the paper's reference arm instead, which is upstream plus patch `0000`
and no matcher changes:

```
scripts/build.sh --baseline build-ref
```

Building both is what reproduces the A/B. Extra CMake flags pass through after
the build directory:

```
scripts/build.sh build -DCOLMAP_MVS_CUDA_NATIVE_BLACKWELL=ON
```

On Blackwell that flag emits native SASS for the dense stereo module rather than
JIT-ing sm_90 PTX. To pin a different upstream revision, set `COLMAP_COMMIT`,
though the numbers below are only claimed for `e8c01c78`.

To apply the series by hand against a checkout you already have:

```
git -C /path/to/colmap checkout e8c01c78
for p in patches/0*.patch; do git -C /path/to/colmap apply "$p"; done
```


Results
-------

### Stage timings

Wall clock per stage, mean +/- standard deviation over n = 10 runs. Ratio is
reference over SERAC, so values above 1 are speedups. Dispersions marked `*`
were not recorded, so those stages cannot be tested formally.

| stage           | reference        | SERAC       | delta    | ratio     | share  |
|-----------------|------------------|-------------|----------|-----------|--------|
| SIFT matching   | 410.5 +/- 7.9 s  | 319.5 +/- 7.0 s | -91.0 s  | **1.28x** | 12.1%  |
| SIFT extraction | 144.0 +/- 0.8 s  | 143.7 s `*` | -0.3 s   | 1.00x     | 4.3%   |
| mapping         | 2830.8 +/- 288.2 s | 3042.3 s `*` | +211.5 s | 0.93x     | 83.6%  |
| end-to-end      | 3385.3 +/- 288.3 s | 3505.5 s  | +120.2 s | 0.97x     | 100%   |

Matching falls by 22.2% of stage time, at Welch t = 27.3 on 17.7 degrees of
freedom. Per-pair matching cost goes from 2.371 to 1.845 ms. Extraction is
unchanged and was never a target; it is reported as a control, so the stage
shares can be read correctly and as a check on the measurement itself. Mapping
runs entirely on the CPU in this build and is untouched by SERAC; its +211.5 s
is 0.73 reference standard deviations and is not distinguishable from
run-to-run variation.

### The gain does not survive to end-to-end time

Matching is 12.1% of reference runtime, so eliminating it *entirely* would give
1.14x. At the measured 1.28x the matcher takes 319.5 s instead of 410.5 s, so a
3385.3 s pipeline would be expected to finish in 3294.3 s, a factor of 1.03x.
The observed ratio is 0.97x, a 120.2 s difference of under one standard error,
so it is not a measured regression either.

The limit is one of measurement resolution as much as of stage share. End-to-end
time is dominated by mapping, whose dispersion is 288.2 s, a coefficient of
variation of 10.2%. At n = 10 per configuration the standard error of an
end-to-end difference is about 129 s, so the smallest change this experiment can
resolve at two standard errors is roughly 258 s. The 91.0 s saving sits at 0.7
standard errors, well inside the noise. Resolving it would take on the order of
80 runs per configuration, and those runs would still mostly be estimating
mapping variance.

This is not an unfavourable configuration for a matcher optimization. Matching
was exhaustive over 589 images, so connectivity is maximal and per-pair cost
matters as much as it can. It still produced no end-to-end gain, because mapping
accounted for 83.6% of runtime.

### GPU kernel time

Per-pair kernel time on a separate profiling subset: 40 images of
*south-building* at 3072x2048, exhaustively matched over 780 pairs, measured
with Nsight Systems.

| kernel                      | reference | SERAC      |
|-----------------------------|-----------|------------|
| `MultiplyDescriptor_Kernel` | 858 us    | **468 us** |
| `RowMatch_Kernel`           | 318 us    | **19 us**  |
| `ColMatch_Kernel`           | 320 us    | **132 us** |
| total per pair              | 1496 us   | **619 us** |
| all 780 pairs               | 1166 ms   | **483 ms** |

GPU time falls 59%. The packed dot product roughly halves the similarity kernel,
the fused reduction removes the row pass almost entirely, and the wider tiles
more than halve the column pass. The optimized similarity kernel runs at 96.7%
compute and 98.1% L1/TEX throughput, meaning it is saturated.

The 59% becomes 22.2% at stage level because much of the stage's wall clock is
host-side work and overlap with CPU geometric verification that the kernels do
not govern. That gap is also why further kernel gains would be increasingly
absorbed.

### Memory

| metric                  | reference  | SERAC      | change      |
|-------------------------|------------|------------|-------------|
| matcher peak GPU memory | 1546 MiB   | 700 MiB    | **-55%**    |
| per-pair intermediate   | 837 MB     | none       | *removed*   |
| raw correspondences     | 26,623,083 | 26,623,083 | *identical* |

COLMAP documents the matcher requirement as roughly `4*M^2 + 1024*M` bytes for
`M` features per image, and advises reducing the match cap when memory is short,
warning that this degrades results because lower-scale features are clamped
away. A memory constraint of this shape is a quality constraint, since the
remedy for running out of memory is to discard features. The term that dominates
it is the intermediate, which no longer exists, so per-pair footprint becomes
linear rather than quadratic in the feature count and the clamping advice no
longer applies.

That ceiling did not bind in the runs above: 1546 MiB against 32.6 GB available.
The memory figures are measured; the quality half of the argument is
architectural, and matters at large feature counts and on small cards.

### Reconstruction quality

One run per configuration. Incremental mapping is stochastic, so the reference
build was also run twice on identical input; that control column is what makes
the comparison readable.

| metric                   | reference   | SERAC       | change   | reference rerun |
|--------------------------|-------------|-------------|----------|-----------------|
| registered images        | 585 / 589   | 585 / 589   | 0        | 585 / 589       |
| 3D points                | 514,012     | 514,066     | +0.011%  | 513,872         |
| observations             | 3,858,610   | 3,859,754   | +0.030%  | 3,858,712       |
| mean track length        | 7.5068      | 7.5083      | +0.020%  | 7.5091          |
| mean observations/image  | 6595.91     | 6597.87     | +0.030%  | 6596.1          |
| mean reprojection error  | 1.00553 px  | 1.00491 px  | -0.060%  | 1.00494 px      |
| accuracy vs GPS          | 4.544 m     | 4.580 m     | +0.79%   | n/a             |
| mapping wall time        | 2627 s      | 3042 s      | +415 s   | 3035 s          |

Registration counts are identical, and every quantity except absolute accuracy
moves by at most 0.06%, with SERAC marginally ahead on points, observations,
track length, and reprojection error. This is what byte-identical matcher output
requires: every movement in the table is mapper nondeterminism, and the rerun
column exhibits the same nondeterminism with no code change at all. The control
moves 3D points by 140 and track length by more than SERAC does.

Absolute accuracy degraded by 0.036 m, which is 0.79% of a 4.5 m baseline set by
consumer GPS rather than by the reconstruction. With one run per configuration
this is not separable from the mapper's nondeterminism.

Mapping wall time behaves the same way. The +415 s gap between reference and
SERAC is reproduced by the reference build against itself (+408 s, 2627 s
against 3035 s), with the divergence traced to a Levenberg-Marquardt
ill-conditioning branch in the final global bundle adjustment. What remains open
is the size of mapping variance, not its cause.

Pairwise geometric agreement, after aligning each pair of reconstructions
(`model_comparer --alignment_error proj_center`, median camera rotation):

| pair                          | median rotation difference |
|-------------------------------|----------------------------|
| reference vs **SERAC**        | **0.0072 deg**             |
| reference vs reference rerun  | 0.0130 deg                 |
| SERAC vs reference rerun      | 0.0067 deg                 |

SERAC agrees with the reference more closely than the reference agrees with
itself across runs.

### What these numbers do not establish

**Quality was measured in aggregate**, one run per configuration plus one
reference rerun. There is no formal equivalence criterion here and no
multi-seed calibration of the mapper, only aggregate agreement plus one control.

**Aggregate statistics have a known blind spot.** On texturally bimodal imagery,
such as glacier surveys where high-contrast bedrock and low-contrast clean ice
sit in the same frame, a degradation confined to the weak stratum leaves four of
five conventional summary statistics flat or improved: registration holds, mean
track length rises because the removed tracks are the short weak ones, mean
reprojection error falls because the discarded observations carried the largest
residuals, and only the point count declines. Global set agreement is not
stratum preserving either, since a candidate preserving a fraction `rho` of
strong keypoints while losing a fraction `l` of weak ones has Jaccard index
`1 - (1-rho)*l`, so at `rho = 0.9` a 30% loss over the surface a survey exists to
measure costs three points of global agreement. Three of the movements above are
that exact signature, so the distinguishing evidence has to be stated rather
than assumed: that failure mode must *reduce* observations while improving their
averages, whereas here observations rose by 1144 and points by 54, and nothing
apart from GPS accuracy moved by more than 0.06%. Per-stratum fidelity has not
been evaluated, and a future change whose effect on the match set is larger than
accumulation noise would need a stratified evaluation before acceptance.

**Mean reprojection error is a censored statistic.** The mapper deletes
observations beyond `filter_max_reproj_error` (4 px by default), so a
correspondence regression surfaces as fewer observations rather than a larger
mean. Read it jointly with the observation count, never on its own.

**The quality comparison cannot fail by construction.** Because the matcher
output is byte-identical, the table confirms the exactness argument end to end;
it does not independently stress it.

**Dispersions were not recorded** for the SERAC extraction and mapping runs, so
only the matching row of the stage table constitutes a formal test. COLMAP's
clamping flag and the GPU idle fraction during matching were not recorded
either. Unit tests were unavailable (`TESTS_ENABLED=OFF`), so matcher
correctness rests on the byte-identity check below rather than on the upstream
suite.

**Two deviations from the measurement protocol** are recorded in the
environment table: clocks were not pinned, and the GPU simultaneously drove an
interactive desktop. Both inflate dispersion, and the 10.2% mapping coefficient
of variation is the expected symptom. This does not threaten the matching
result, whose effect is 27 standard errors, but it loosens the mapping and
end-to-end figures.


What changed
------------

**Descriptor inner product (DP4A).** The 128-dimensional descriptor dot product
was evaluated as 128 scalar `__mul24` calls. `__mul24` has not been a native
instruction since Fermi and lowers to an emulation sequence on the FMA pipe;
profiling showed the kernel pinned at 84.7% SM throughput. Folding each group of
four byte products into one `__dp4a` gives 32 instructions instead of 128, and
is bit-exact for unsigned 8-bit operands accumulated in 32 bits. A scalar
fallback is retained for pre-sm_61 targets.

**Fused row reduction.** The matcher materialized a full `num1 x num2` matrix of
inner products in device memory and read all of it back to select a best and
second-best per row. The column direction already avoided this with per-block
partials, so the row direction now does the same via warp shuffles. The matrix is
never written. This removes an allocation that was quadratic in the feature
count, 837 MB on this dataset, and eliminates the round trip.

**Wider tiles.** Matching 16 descriptor rows per block instead of 8 halves both
the descriptor re-reads and the column-partial table the reduction consumes.

**Dense stereo working set** (patch `0000`, not measured). PatchMatch cost and
selection-probability maps are stored as half precision with float arithmetic,
and a code-generation workaround is included for an NVCC miscompilation of
dynamically indexed local arrays when emitting native SASS for Blackwell. This
patch is applied to both arms of the A/B, so it cancels out of every number
above. It is outside the scope of the measurements and is unevaluated here.


Exactness
---------

The matcher rewrite is exact rather than approximate:

- `__dp4a` on unsigned bytes into a 32-bit accumulator cannot overflow for
  128-dimensional SIFT descriptors, so it is arithmetically identical to the
  scalar sequence it replaces.
- The fused reduction seeds each lane from the identity `(0, -1, 0)` and keeps
  the left operand on ties, reproducing the original scan's zero floor and
  ratio-test semantics.
- Verified by SHA-256 over all 173,166 correspondence blobs (213 MB, 26,623,083
  correspondences): identical between the two builds.
- Confirmed in the shipped binary rather than only in source: disassembly
  contains 1024 DP4A instructions, 512 in each of the two matcher kernels, in
  native sm_120 SASS.

One documented caveat: on an exact top-1 tie the reference returns the tied
column with the smallest `col mod 32`, while SERAC returns the smallest column.
This cannot change a reported match for `max_ratio <= 1` (the default is 0.8),
because a tie forces `second_best == best` and the ratio test then rejects the
row in both builds. The note on `MergeBest` is carried in
`patches/0004-tie-break-note.patch`, and lands in
`src/thirdparty/SiftGPU/ProgramCU.cu` once the series is applied.

Matching as implemented here is deterministic, so an exact comparison exists.
GPU feature extraction and incremental mapping are not run-to-run deterministic
in COLMAP, which is why they are compared against same-binary control runs
instead.


Environment
-----------

Results above were produced on:

| component  | version |
|------------|---------|
| GPU        | NVIDIA GeForce RTX 5090, Blackwell sm_120, 170 SMs, 32.6 GB GDDR7, 575 W, persistence mode on |
| CPU        | AMD Ryzen 7 9700X, 8C/16T |
| CUDA       | 13.3 (V13.3.33), driver 610.43.02, native sm_120 SASS (`CMAKE_CUDA_ARCHITECTURES=native`), no PTX JIT |
| Compiler   | GCC 13.3.0, CMake 3.28.3, Ninja 1.11.1 |
| OS         | Ubuntu 24.04.4 LTS, kernel 7.0.0-29 |
| Profilers  | Nsight Systems 2026.1.3, Nsight Compute 2026.2.0 |

Two deviations from the protocol, noted above: GPU clocks were not pinned, and
the device concurrently served an interactive desktop (about 1.9 GiB held).

**Builds.** Both binaries were built from COLMAP 4.1.0.dev0 in Release mode
(`-O3 -DNDEBUG`) with CUDA, SIMD, and GUI enabled, from upstream `e8c01c78` with
patch `0000` applied. That tree is the reference arm; the SERAC arm adds patches
`0001` through `0004` and nothing else. `TESTS_ENABLED=OFF` left the unit tests
unavailable.

**Data.** A 589 image UAV survey at 4000x3000 (2.9 GB, DJI FC330 at 3.61 mm,
GPS in EXIF), carrying roughly 10,400 features per image and matched
exhaustively over all 173,166 pairs. Kernel-level profiling used a 40 image
subset of *south-building* at 3072x2048, exhaustively matched over 780 pairs.

**Method notes.** The GPU was verified idle before each timed run, the page
cache was pre-warmed so both builds read images warm, and the A/B ran on
byte-identical input databases. Same-binary control runs were used to establish
noise floors for the nondeterministic stages.

**Start every timed run from a fresh database.** COLMAP skips pairs that already
possess a two-view geometry, so reusing a database makes the matcher appear
nearly free. This will silently inflate any published COLMAP matcher timing,
including the ones above had they not been controlled for.

Licensing
---------

This repository contains only SERAC's own work, released under BSD-3-Clause
(see `LICENSE`). No COLMAP or SiftGPU source is redistributed here; `build.sh`
fetches it from upstream at build time, so each project reaches you under its
own terms.

Two of those terms are worth knowing before you build on this:

- **COLMAP** is BSD-3-Clause, Copyright (c) ETH Zurich and UNC Chapel Hill. If
  you redistribute a patched COLMAP tree rather than this patch series, that
  license requires you to retain its copyright notice, conditions, and
  disclaimer in the source you ship.
- **SiftGPU**, which supplies the files these patches modify
  (`src/thirdparty/SiftGPU/`), is Copyright (c) 2007 University of North
  Carolina at Chapel Hill, by Changchang Wu, and is granted "for educational,
  research and non-profit purposes" only. It is not a BSD license and it is not
  a permissive one. A patched matcher inherits that restriction, so commercial
  use needs permission from the copyright holder regardless of how this
  repository is licensed.

The patch files quote a few lines of upstream context around each hunk, as
unified diffs do. Attribution for the code being modified stays with the
upstream projects.


Paper
-----

The numbers in this README are the ones reported in `paper/01-manuscript.tex`:

> *A Fused Descriptor Matcher for COLMAP: Stage Speedup Without End-to-End Gain.*
> SiCheng Zhao, Arjun Pakrashi, Soumyabrata Dev.

The manuscript names SERAC as the agentic search loop that found and validated
the edit, under a verification boundary that is unreachable by mechanism rather
than forbidden by instruction: the harness repository is read-only, a non-LLM
static gate rejects any diff touching it, the driver hashes the effective
options at runtime and refuses to score a mismatch, and an execution-path
assertion confirms the CUDA path actually ran rather than the OpenGL or CPU
fallback. The patch series in this repository is what it produced.
