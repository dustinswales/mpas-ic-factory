# MPAS IC factory

Creates MPAS static, initial-condition, lateral-boundary and surface-update files for a fixed set of test cases, on GitHub Actions or by hand on any Linux machine.

It is a standalone, CI-driven version of the `create_case` step in [barlage/mpas_testcase](https://github.com/barlage/mpas_testcase). The case namelists in `case_files/` are copied unchanged from there. Output file names and the directory layout are also the same, so files from either source can be compared directly.

## Cases

Defined in [`cases.yaml`](cases.yaml) (the old `create_mpas_testcase_case01..08.sh`):

| case | code base | namelist | domain | source | date |
|---|---|---|---|---|---|
| case01 | ncar | ncar | conus | gfs | 2023-03-10 15Z |
| case02 | ncar | ncar | global | gfs | 2023-03-10 15Z |
| case03 | gsl | ncar | conus | gfs | 2023-03-10 15Z |
| case04 | gsl | ncar | global | gfs | 2023-03-10 15Z |
| case05 | gsl | gsl | conus | gfs | 2023-03-10 15Z |
| case06 | gsl | gsl | global | gfs | 2023-03-10 15Z |
| case07 | gsl | gsl | conus | rap (winter) | 2024-02-02 18Z |
| case08 | gsl | gsl | conus | rap (summer) | 2024-08-15 18Z |

All cases use the 120 km mesh (`x1.40962` global, `conus.120km` regional) and climatological aerosols.

Each case writes `<code_base>.<namelist>.<domain>.120km.<source>.<yyyymmddhh>/case_files/` containing:

- `mpas.*.static.nc`
- `mpas.*.ugwp_oro_data.nc` (gsl namelist only)
- `mpas.*.init.<date>.nc`
- `mpas.*.lbc.<date>.nc` (conus only; one file holding all 3-hourly records)
- `mpas.*.sfc_update.<date>.nc` (gfs only)
- `log.*`
- `description` (provenance: code repo, ref, commit, toolchain, input tag)
- `SHA256SUMS`

The **code base** decides which repository `init_atmosphere_model` is built from:

- `ncar` defaults to `MPAS-Dev/MPAS-Model@v8.3.0`.
- `gsl` defaults to `ufs-community/MPAS-Model@noaa/develop`.

Change the defaults in `cases.yaml`, or override them per run.

## Running on GitHub Actions

Actions → **Create MPAS cases** → *Run workflow*. The inputs are:

- **cases**: `all` or a comma list, e.g. `case05,case07`.
- **ncar_repo / ncar_ref, gsl_repo / gsl_ref**: any fork plus a branch, tag or SHA. Use these to test a PR branch.
- **inputs_tag**: the release holding the input bundles (see below).
- **baseline_tag**: a previously published release to compare against with `nccmp -dsSqf`. The result appears in the run summary.
- **publish_tag**: publish this run's cases as a new release, one `<case_dir>.tar` per case.
- **precision** and **debug**: build options.

The run has five stages:

1. **setup** reads `cases.yaml` and resolves each code base to a commit.
2. **build** compiles `init_atmosphere_model` with conda-forge GNU compilers, MPICH and parallel netCDF/PnetCDF (`env/environment.yml`). The executable is cached per commit.
3. **static** makes one static file per (code base, namelist, domain). This is the slow step and the only one that needs the geographic data. Its result is cached on commit, static namelist, toolchain and input tag, so it reruns only when one of those changes.
4. **case** runs init, lbc and sst for each case in parallel and uploads the `case_files` directory as an artifact.
5. **report** compares with the baseline and/or publishes the release (optional).

Graph partitions are generated with `gpmetis` for the runner's core count, so no prebuilt `graph.info.part.N` files are needed.

## Input bundles (one-time setup)

GitHub runners cannot see `/scratch4`. The inputs therefore live as assets of a release in this repository (default tag `inputs-v1`). `scripts/fetch_inputs.sh` downloads them and checks them against `MANIFEST.sha256`:

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

Override the source paths with `SYSTEM_DIR`, `GLOBAL_GRID_DIR`, `CONUS_GRID_DIR`, `UNGRIB_DIR`, `AEROSOL_FILE`, `GEOG_DIR` or `GEOG_SUBDIRS` (see the script header). To change inputs later, stage a new tag (`-t inputs-v2`) rather than overwriting the old one; the static cache is keyed on the tag.

## Running by hand

```bash
conda env create -f env/environment.yml && conda activate mpas-ic   # or your own modules
scripts/build_init_atmosphere.sh /path/to/MPAS-Model bin/init_atmosphere_model
scripts/fetch_inputs.sh -r OWNER/mpas-ic-factory -t inputs-v1 -d inputs \
    grids geog aerosols ungrib-gfs.2023031015 ungrib-sst.2023031015
scripts/create_case.sh -c case05 -e bin/init_atmosphere_model -i inputs -o cases -n 8
```

`create_case.sh` takes the launcher from `MPIRUN` (default `mpirun -n`; `MPIRUN="srun -n"` under Slurm). Other options:

- `-s static,init,lbc,sst` runs a subset of the steps.
- `-S DIR` reuses an existing static file.
- `-k` keeps the run directories.

Compare two trees with `scripts/compare_cases.sh BASE_DIR TEST_DIR`.

## Layout

```
cases.yaml                case definitions, dates, meshes, default code refs
case_files/{ncar,gsl}/    namelist.init_atmosphere + streams per step (from mpas_testcase)
scripts/create_case.sh    one case, any machine
scripts/case_info.py      cases.yaml -> shell settings / Actions matrices
scripts/resolve_refs.py   code base -> repo, ref, commit
scripts/build_init_atmosphere.sh
scripts/fetch_inputs.sh   release bundles -> input tree
scripts/compare_cases.sh  nccmp report
tools/stage_inputs.sh     input tree -> release bundles (run once on HPC)
env/environment.yml       conda-forge toolchain
.github/workflows/        create-cases.yml, lint.yml
```

## Runner limits

The workflow is written for standard GitHub-hosted Linux runners. On public repositories these have 4 vCPU and 16 GB of memory; on private repositories, 2 vCPU and 7 GB.

- The global static step on 4 cores is the long pole, with a 340-minute timeout. Because the static result is cached, it runs only once per code commit.
- The `geog` bundle has to fit on the runner disk. The static job frees about 20 GB before downloading it.
