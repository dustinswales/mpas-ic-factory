# Local patches to MPAS-Model

`scripts/build_init_atmosphere.sh` applies every `*.patch` here (in name order) to the MPAS checkout before building. A patch that is already in the source is skipped, so it is harmless once the fix lands upstream. A patch that no longer applies stops the build. The executable and static-file caches are keyed on these files.

| patch | why | upstream |
|---|---|---|
| `0001-nullify-aerosol-fg-pointers.patch` | `smoke_fine_fg`, `dust_fine_fg`, `dust_coarse_fg` in `init_atm_case_gfs` and `init_atm_case_lbc` are only set when `config_smoke_scheme` / `config_dust_scheme` are on, but are tested with `associated()`. With the schemes off they are undefined: gfortran builds segfault in the init step (bounds check: `mpas_init_atm_cases.F:7357`, index below lower bound of `dust_fine_fg`). | to open in ufs-community/MPAS-Model |

To drop a patch after the fix is merged upstream, delete the file.
