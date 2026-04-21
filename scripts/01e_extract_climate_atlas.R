## 01e_extract_climate_atlas.R — UH Climate Atlas RAR → GeoTIFF on HCDP grid
## MIH Pipeline Sub-step 01e
## ────────────────────────────────────────────────────────────────────────────
##
## Purpose:
##   Extract the six UH Climate Atlas monthly-climatology layers from their
##   ESRI-grid .rar archives (Giambelluca et al. 2014) and write each as a
##   GeoTIFF. Producing loose GeoTIFFs makes them directly readable by the
##   main step script (via /vsizip/ into the bundle, or unzip to a scratch
##   dir) without every consumer having to carry AIG-driver and unrar
##   dependencies.
##
##   Contemporary-stack layers only. Not used on the historic stack —
##   Climate Atlas products are 2014-vintage and cannot represent 1960s
##   Hawaii landscape (see PROVENANCE.md).
##
## Inputs (six ClimateAtlas RARs + canonical DEM as geometry reference):
##   data/public/01_ClimateAtlas_VPD_month_Pa.rar
##   data/public/01_ClimateAtlas_RH_month_pct.rar
##   data/public/01_ClimateAtlas_EVI_month.rar
##   data/public/01_ClimateAtlas_NDVI_month.rar
##   data/public/01_ClimateAtlas_FracVegCover_month.rar
##   data/public/01_ClimateAtlas_CloudFreq_month.rar
##   data/public/01_DEM_hawaii_statewide_canonical.tif   (HCDP-grid reference)
##
## Output:
##   outputs/01e_climate_atlas_geotiff.zip
##     78 GeoTIFFs flat (zip -j9), 6 variables × 13 grids:
##       vpd_{01..12,ann}.tif,   rh_{01..12,ann}.tif,
##       evi_{01..12,ann}.tif,   ndvi_{01..12,ann}.tif,
##       fvc_{01..12,ann}.tif,   cloudfreq_{01..12,ann}.tif
##   Pushed to Drive at the same path.
##
## Working pattern:
##   mih_new_scratch() twice — one for RAR extraction, one for GeoTIFF
##   scratch outputs. Also isolates terra's internal tempdir so terra's
##   housekeeping can't sweep files the script still needs. Both dirs are
##   torn down on R process exit; no manual on.exit() required.
##
## Archive layout (verified April 2026 via MIH_probe_01e.R on VPD and
## historically on all six archives):
##   Each RAR contains one wrapper folder "{Product}_month_raster/" holding
##   13 ESRI grid subfolders (12 months + 1 annual) plus a shared "info/"
##   workspace required by GDAL's AIG driver. Grid-folder stems differ
##   across products — mostly simple {var}_ prefixes, but FracVegCover
##   ships as "fr_v_c_*" and CloudFreq ships as "cl_frq_*" (note the
##   underscored stems). The dispatch table below encodes each variable's
##   archive stem explicitly rather than relying on a prefix heuristic.
##
## Geometry (verified bit-identical across all 6 archives):
##   CRS WGS84, extent (-159.816, -154.668, 18.849, 22.269),
##   resolution 0.00225°, dims 1520 × 2288, FLT4S. Native HCDP grid;
##   no resampling needed. compareGeom against the canonical DEM asserts
##   this archive-by-archive; a mismatch is fatal because hiding it would
##   mask either an archive-level product change or a wrong delivery.

library(conflicted)
library(here)
library(terra)
library(googledrive)

conflicted::conflicts_prefer(base::intersect)
conflicted::conflicts_prefer(base::setdiff)

source(here::here("scripts/_pipeline_boilerplate.R"))

## ── 1. Preflight ──────────────────────────────────────────────────────────

if (Sys.which("unrar") == "") {
  stop("`unrar` binary not found on PATH.",
       "\n  On Debian/Ubuntu: sudo apt install unrar",
       "\n  Climate Atlas archives are distributed only as RAR.")
}

terra::terraOptions(progress = 0)

## ── 2. Variable dispatch table ────────────────────────────────────────────
## Per-variable:
##   prefix   output-filename stem (what consumers see)
##   stem     in-archive grid-folder stem (what unrar produces)
##   rar      canonical filename under data/public/
##   upstream original UH filename at atlas.uhtapis.org/evapo for fetch_fn
##   unit     display unit for the per-grid report
##   n_nonNA  catalog-appendix non-NA count, checked on the annual grid
##   label    human-readable name for log messages
##
## FracVegCover and CloudFreq stems differ from their output prefixes and
## from a simple {prefix}_ pattern. Verified directly from archive contents.

ATLAS_URL <- "http://atlas.uhtapis.org/evapo/assets/files/GridFiles/"

VARS <- list(
  list(prefix = "vpd",       stem = "vpd",
       rar = "01_ClimateAtlas_VPD_month_Pa.rar",
       upstream = "VPD_month_raster.rar",
       unit = "Pa",       n_nonNA = 287971L,
       label = "VPD (vapor pressure deficit)"),
  list(prefix = "rh",        stem = "rh",
       rar = "01_ClimateAtlas_RH_month_pct.rar",
       upstream = "RH_month_raster.rar",
       unit = "%",        n_nonNA = 287971L,
       label = "RH (relative humidity)"),
  list(prefix = "evi",       stem = "evi",
       rar = "01_ClimateAtlas_EVI_month.rar",
       upstream = "EVI_month_raster.rar",
       unit = "unitless", n_nonNA = 287971L,
       label = "EVI"),
  list(prefix = "ndvi",      stem = "ndvi",
       rar = "01_ClimateAtlas_NDVI_month.rar",
       upstream = "NDVI_month_raster.rar",
       unit = "unitless", n_nonNA = 287971L,
       label = "NDVI"),
  list(prefix = "fvc",       stem = "fr_v_c",
       rar = "01_ClimateAtlas_FracVegCover_month.rar",
       upstream = "FractionalVegetationCover_month_raster.rar",
       unit = "ratio",    n_nonNA = 287978L,
       label = "FracVegCover"),
  list(prefix = "cloudfreq", stem = "cl_frq",
       rar = "01_ClimateAtlas_CloudFreq_month.rar",
       upstream = "CloudFreq_month_raster.rar",
       unit = "ratio",    n_nonNA = 287978L,
       label = "CloudFreq (cloud frequency)")
)

MONTH_NUM <- c(jan = "01", feb = "02", mar = "03", apr = "04",
               may = "05", jun = "06", jul = "07", aug = "08",
               sep = "09", oct = "10", nov = "11", dec = "12")
SUFFIXES  <- c(names(MONTH_NUM), "ann")   # 13 suffixes total

## ── 3. Reference geometry: canonical DEM ──────────────────────────────────
## Canonical DEM is the HCDP-grid authority (built by 01a). Climate Atlas
## is catalogued pixel-identical to HCDP; comparing each grid against DEM
## asserts both (a) internal consistency across the six archives and
## (b) alignment with the pipeline's HCDP-grid anchor.

dem_path <- resolve(
  local_path = "data/public/01_DEM_hawaii_statewide_canonical.tif",
  drive_path = "MIH_Mosquitoes_Hawaii/data/public/01_DEM_hawaii_statewide_canonical.tif"
)
ref_rast <- terra::rast(dem_path)

## ── 4. Scratch directories ────────────────────────────────────────────────

extract_dir <- mih_new_scratch("mih_01e_extract_")
scratch     <- mih_new_scratch("mih_01e_scratch_")

## ── 5. Per-variable processing ────────────────────────────────────────────

process_variable <- function(var) {
  message("\n--- ", var$label, " ---")

  ## Tier 1 local → tier 2 Drive → tier 3 direct UH download.
  ## Size floor 1 MB catches truncated caches; the smallest archive (EVI)
  ## is 2.3 MB so the floor leaves ample margin.
  rar_path <- resolve(
    local_path = file.path("data/public", var$rar),
    drive_path = file.path("MIH_Mosquitoes_Hawaii/data/public", var$rar),
    fetch_fn   = function(path) {
      utils::download.file(
        paste0(ATLAS_URL, var$upstream),
        destfile = path, mode = "wb", quiet = TRUE
      )
    },
    validate   = function(p) file.info(p)$size > 1e6
  )

  ## Per-variable extraction subdir — keeps archive workspaces isolated in
  ## case two archives share a top-level folder name.
  xdir <- file.path(extract_dir, var$prefix)
  dir.create(xdir, recursive = TRUE, showWarnings = FALSE)

  ## `x` = extract with full paths, `-y` = yes to all, `-o+` = overwrite.
  ## Trailing slash on dest tells unrar it's a directory. stdout/stderr
  ## captured so a non-zero exit can surface the last lines in the error.
  out    <- system2("unrar",
                    args   = c("x", "-y", "-o+", rar_path, paste0(xdir, "/")),
                    stdout = TRUE, stderr = TRUE)
  status <- attr(out, "status"); if (is.null(status)) status <- 0L
  if (status != 0L) {
    stop(sprintf(
      "unrar failed for %s (exit %d).\n  Tail:\n    %s",
      basename(rar_path), status,
      paste(utils::tail(out, 10), collapse = "\n    ")))
  }

  ## Locate grid folders by exact {stem}_{suffix} match. Recursive walk
  ## tolerates the archive's wrapper folder ({Product}_month_raster/).
  all_dirs  <- list.dirs(xdir, recursive = TRUE, full.names = TRUE)
  expected  <- paste(var$stem, SUFFIXES, sep = "_")
  grid_dirs <- all_dirs[basename(all_dirs) %in% expected]

  if (length(grid_dirs) != 13L) {
    stop(sprintf(
      "%s: expected 13 grid folders matching '%s_{%s}', found %d.\n  Archive: %s",
      var$label, var$stem, paste(SUFFIXES, collapse = "|"),
      length(grid_dirs), basename(rar_path)))
  }
  missing_suf <- setdiff(expected, basename(grid_dirs))
  if (length(missing_suf) > 0L) {
    stop(sprintf("%s: missing grid folders: %s",
                 var$label, paste(missing_suf, collapse = ", ")))
  }

  for (d in grid_dirs) {
    suf <- sub(paste0("^", var$stem, "_"), "", basename(d))
    r   <- terra::rast(d)

    if (!isTRUE(terra::compareGeom(r, ref_rast,
                                   stopOnError = FALSE, messages = FALSE))) {
      stop(sprintf(
        "%s/%s: geometry differs from canonical HCDP-grid DEM.\n  Expected: WGS84 0.00225°, extent −159.816/−154.668/18.849/22.269, 1520 × 2288.",
        var$prefix, basename(d)))
    }

    out_name <- if (suf == "ann") {
      sprintf("%s_ann.tif", var$prefix)
    } else {
      sprintf("%s_%s.tif", var$prefix, unname(MONTH_NUM[suf]))
    }
    out_path <- file.path(scratch, out_name)

    terra::writeRaster(
      r, out_path, overwrite = TRUE,
      datatype = "FLT4S",
      gdal     = c("COMPRESS=DEFLATE", "PREDICTOR=3", "TILED=YES")
    )

    ## Per-grid report — cheap scan for mask drift, unit surprise, or NA
    ## leakage. Matches 01d's write_normals idiom.
    n_valid <- unname(terra::global(r, "notNA")[1, 1])
    rng     <- unname(terra::global(r, c("min", "max"), na.rm = TRUE)[1, ])
    message(sprintf("  %-18s  notNA=%6d  range=[%9.4f, %9.4f] %s",
                    out_name, n_valid, rng[1], rng[2], var$unit))
  }

  ## Annual-grid non-NA count vs catalog, 1% tolerance. One-shot archive
  ## sanity check; absorbs benign precision differences while catching a
  ## wrong-product delivery.
  ann_path <- file.path(scratch, sprintf("%s_ann.tif", var$prefix))
  n_obs    <- terra::global(terra::rast(ann_path), "notNA")[1, 1]
  if (abs(n_obs - var$n_nonNA) / var$n_nonNA > 0.01) {
    stop(sprintf(
      "%s: annual grid has %d non-NA cells, catalog expects ~%d.",
      var$label, n_obs, var$n_nonNA))
  }
}

for (v in VARS) process_variable(v)

## ── 6. Post-write re-read verification ────────────────────────────────────
## Re-open every written TIF and compareGeom against the first. Catches
## any writeRaster surprise (datatype coercion, tiling block rewrite)
## that would shift geometry between the in-memory raster and the on-disk
## file before the bundle is shipped downstream.

out_files <- list.files(scratch, pattern = "\\.tif$", full.names = TRUE)
if (length(out_files) != 78L) {
  stop(sprintf("Expected 78 TIFs in scratch before bundling, found %d.",
               length(out_files)))
}

ref_written <- terra::rast(out_files[1])
mismatched  <- character()
for (f in out_files[-1]) {
  if (!isTRUE(terra::compareGeom(terra::rast(f), ref_written,
                                 stopOnError = FALSE, messages = FALSE))) {
    mismatched <- c(mismatched, basename(f))
  }
}
if (length(mismatched) > 0L) {
  stop(sprintf(
    "Grid mismatch across %d of %d written outputs.\n  First: %s",
    length(mismatched), length(out_files),
    paste(utils::head(mismatched, 5), collapse = ", ")))
}

## ── 7. Bundle scratch into zip output and push to Drive ───────────────────
## Flat layout via -j per PIPELINE_SPEC — the 01e bundle is 78 TIFs, no
## subdirs. -9 for max compression; TIFs already have internal DEFLATE so
## gain is modest but consistent with 01c convention.

bundle_rel  <- "outputs/01e_climate_atlas_geotiff.zip"
bundle_path <- here::here(bundle_rel)
dir.create(dirname(bundle_path), recursive = TRUE, showWarnings = FALSE)

message(sprintf("\nBundling %d TIFs into %s",
                length(out_files), basename(bundle_path)))

zip_status <- utils::zip(zipfile = bundle_path, files = out_files, flags = "-j9")
if (zip_status != 0L || !file.exists(bundle_path)) {
  stop("Bundle creation failed (zip exit status ", zip_status, ").",
       "\n  Expected output: ", bundle_path)
}

push_output(bundle_path, bundle_rel)

## ── 8. Final summary ──────────────────────────────────────────────────────

message(sprintf("\nSub-step 01e complete. 6 archives → %d TIFs bundled.",
                length(out_files)))
message(sprintf("Bundle: %s (%.1f MB)",
                bundle_path, file.size(bundle_path) / 1024^2))
