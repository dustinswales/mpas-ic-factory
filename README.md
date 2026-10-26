# MPAS IC factory

Creates MPAS static, initial-condition, lateral-boundary and surface-update files for a fixed set of test cases, on GitHub Actions or by hand on any Linux machine.

It is a standalone, CI-driven version of the `create_case` step in [barlage/mpas_testcase](https://github.com/barlage/mpas_testcase), reduced to the GSL code and namelists (the old cases 05–08). The namelists in `case_files/` are copied unchanged from that repository's `case_files/gsl/`.

## Cases

Defined in [`cases.yaml`](cases.yaml):

| case | domain | source | date |
|---|---|---|---|
| conus_gfs  | conus  | gfs | 2023-03-10 15Z |
| global_gfs | global | gfs | 2023-03-10 15Z |
| conus_rapw | conus  | rap (winter) | 2024-02-02 18Z |
| conus_raps | conus  | rap (summer) | 2024-08-15 18Z |

All cases use the 120 km mesh (`x1.40962` global, `conus.120km` regional) and climatological aerosols. `init_atmosphere_model` is built from `ufs-community/MPAS-Model@noaa/develop` by default; change the default in `cases.yaml`, or override it per run.

Each case writes `<domain>.120km.<source>.<yyyymmddhh>/case_files/` containing:

- `mpas.<domain>.120km.static.nc`
- `mpas.<domain>.120km.ugwp_oro_data.nc`
- `mpas.<domain>.120km.<source>.init.<date>.nc`
- `mpas.<domain>.120km.<source>.lbc.<date>.nc` (conus only; one file holding all 3-hourly records)
- `mpas.<domain>.120km.<source>.sfc_update.<date>.nc` (gfs only)
- `log.*`
- `description` (provenance: code repo, ref, commit, toolchain, input tag)
- `SHA256SUMS`

Compared with `mpas_testcase`, the `gsl.gsl.` part is dropped from the directory and file names (`gsl.gsl.conus.120km.gfs.2023031015/…/mpas.gsl.gsl.conus.120km.static.nc` becomes `conus.120km.gfs.2023031015/…/mpas.conus.120km.static.nc`).

## Running on GitHub Actions

Actions → **Create MPAS cases** → *Run workflow*. The inputs are:

- **cases**: `all` or a comma list, e.g. `conus_gfs,...`.
- **mpas_repo / mpas_ref**: any fork plus a branch, tag or SHA. Use these to test a PR branch.
- **inputs_tag**: the release holding the input bundles (see below).
- **baseline_tag**: a previously published release to compare against with `nccmp -dsSqf`. The result appears in the run summary.
- **publish_tag**: publish this run's cases as a new release, one `<case_dir>.tar` per case.
- **static_tag**: a release of prebuilt static files (see *Prebuilt static files*). The static step downloads the ones it finds there and computes any that are missing; blank computes them all in CI.
- **static_runner**: runner label for the static job, e.g. a larger runner if your GitHub plan has them.
- **precision**: build option.
- **debug**: `on` builds with `-g`, bounds checking and backtraces; `on+fpe` also traps floating-point exceptions (MPAS's own debug flags).

The run has five stages:

1. **setup** reads `cases.yaml` and resolves the code ref to a commit.
2. **build** compiles `init_atmosphere_model` with conda-forge GNU compilers, MPICH and parallel netCDF/PnetCDF (`env/environment.yml`). The executable is cached per commit.
3. **static** makes one static file per domain (conus, global). This is the slow step and the only one that needs the geographic data. Its result is cached on commit, static namelist, toolchain and input tag, so it reruns only when one of those changes.
4. **case** runs init, lbc and sst for each case in parallel and uploads the `case_files` directory as an artifact.
5. **report** compares with the baseline and/or publishes the release (optional).

Graph partitions are generated with `gpmetis` for the runner's core count, so no prebuilt `graph.info.part.N` files are needed.

## Input bundles (one-time setup)

GitHub runners cannot see `/scratch4`. The inputs therefore live as assets of a release in this repository (default tag `v1.0.0`). `scripts/fetch_inputs.sh` downloads them and checks them against `MANIFEST.sha256`:

| bundle | contents |
|---|---|
| `grids` | `x1.40962.grid.nc`, `conus.120km.grid.nc`, and their `.graph.info` |
| `geog` | the `mpas_static` datasets the static namelists read (split into < 2 GB parts) |
| `aerosols` | `QNWFA_QNIFA_SIGMA_MONTHLY.dat` |
| `ungrib-gfs.2023031015`, `ungrib-sst.2023031015` | ungrib intermediate files (`GFS:*`, `SST:*`) |
| `ungrib-rap.2024020218`, `ungrib-rap.2024081518` | ungrib intermediate files (`RAP:*`) |

Make them once on the machine that has the data (defaults follow the Ursa layout used by `mpas_testcase`):

```bash
tools/stage_inputs.sh /path/to/stage                      # package only
tools/stage_inputs.sh -u OWNER/mpas-ic-factory /path/to/stage   # package and upload (needs gh)
```

Override the source paths with `SYSTEM_DIR`, `GLOBAL_GRID_DIR`, `CONUS_GRID_DIR`, `UNGRIB_DIR`, `AEROSOL_FILE`, `GEOG_DIR` or `GEOG_SUBDIRS` (see the script header). To change inputs later, stage a new tag (`-t v2.0.0`) rather than overwriting the old one; the static cache is keyed on the tag.

## Prebuilt static files

The static step reads the large geographic datasets and is slow, but it depends only on the code version and the static namelist. To skip it in CI, package static files already made on HPC:

```bash
bash tools/stage_static.sh -u OWNER/mpas-ic-factory -t static-v1 \
    /path/to/create_case/output /path/to/stage
```

`SOURCE_DIR` can be any directory holding `*<domain>.120km.static.nc` and `*<domain>.120km.ugwp_oro_data.nc` for conus and global, including a `mpas_testcase` baseline directory (the `gsl.gsl.` names are renamed on the way in). Then run the workflow with `static_tag=static-v1`. Static files the release does not have, such as the `lakes` variant, are still computed in CI. Make a new tag whenever the code version that should produce the static files changes.

## Static variants and MODIS land use with lakes

A case with `static_variant: X` in `cases.yaml` uses the step-1 namelist in `case_files/step1_static_X/` and gets its own static file. `conus_rapw` and `conus_raps` use the `lakes` variant: `config_landuse_data = 'MODIFIED_IGBP_MODIS_NOAH_LAKES'`, 21-class MODIS land use with lakes as category 21 (from `patches/mpas/0002`). It reads the WPS dataset `modis_landuse_20class_30s_with_lakes`, which is added to an existing inputs release with:

```bash
bash tools/add_geog_dataset.sh -u OWNER/mpas-ic-factory /path/to/stage \
    /path/to/WPS_GEOG/modis_landuse_20class_30s_with_lakes
```

`fetch_inputs.sh` fetches every `geog-<dataset>` bundle whenever `geog` is requested.

## Running by hand

```bash
conda env create -f env/environment.yml && conda activate mpas-ic   # or your own modules
scripts/build_init_atmosphere.sh /path/to/MPAS-Model bin/init_atmosphere_model
scripts/fetch_inputs.sh -r OWNER/mpas-ic-factory -t v1.0.0 -d inputs \
    grids geog aerosols ungrib-gfs.2023031015 ungrib-sst.2023031015
scripts/create_case.sh -c conus_gfs -e bin/init_atmosphere_model -i inputs -o cases -n 8
```

`create_case.sh` takes the launcher from `MPIRUN` (default `mpirun -n`; `MPIRUN="srun -n"` under Slurm). Other options:

- `-s static,init,lbc,sst` runs a subset of the steps.
- `-S DIR` reuses an existing static file.
- `-k` keeps the run directories.

Compare two trees with `scripts/compare_cases.sh BASE_DIR TEST_DIR`.

## Layout

```
cases.yaml                case definitions, dates, meshes, default code ref
case_files/               namelist.init_atmosphere + streams per step (from mpas_testcase gsl)
scripts/create_case.sh    one case, any machine
scripts/case_info.py      cases.yaml -> shell settings / Actions matrices
scripts/resolve_refs.py   code ref -> commit
scripts/build_init_atmosphere.sh
scripts/fetch_inputs.sh   release bundles -> input tree
scripts/compare_cases.sh  nccmp report
tools/stage_inputs.sh     input tree -> release bundles (run once on HPC)
tools/add_geog_dataset.sh add one geographic dataset to an existing inputs release
tools/stage_static.sh     existing static files -> release bundles (optional)
tools/check_intermediate.py  scan ungrib intermediate files for NaN/Inf and damaged records
patches/mpas/             local fixes applied to MPAS before building (see its README)
env/environment.yml       conda-forge toolchain
.github/workflows/        create-cases.yml, lint.yml
```

## Runner limits

The workflow is written for standard GitHub-hosted Linux runners. On public repositories these have 4 vCPU and 16 GB of memory; on private repositories, 2 vCPU and 7 GB.

- The global static step is the long pole. GitHub-hosted jobs stop after 6 hours, and on a 4-core runner the global static file may not finish in time (the job is then killed with signal 15). Use **static_tag** or a larger **static_runner** for it. A computed static file is cached only when its job succeeds.
- The `geog` bundle has to fit on the runner disk. The static job frees about 20 GB before downloading it.
