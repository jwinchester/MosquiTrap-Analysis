## 02_occurrence_clean.R — QC, ocean snapping, spatial thinning
## MIH Pipeline Step 02
## ────────────────────────────────────────────────────────────────────────────

library(here)
library(conflicted)
library(googledrive)
library(readr)
library(dplyr)
library(terra)

source(here::here("scripts/_pipeline_boilerplate.R"))

conflicts_prefer(dplyr::filter, dplyr::lag, dplyr::select, dplyr::mutate,
                 base::intersect, base::setdiff)

## -- Configuration -----------------------------------------------------------

## Stack to use for ocean snapping and coordinate validation.
## Options: "trackA_contemporary", "trackB_contemporary", "trackB_historic"
## (Track A historic retired per decision #17; use trackB_historic for any
##  historic validation needed.)
STACK <- "trackB_contemporary"

## Thinning distance in kilometers (decision #4 resolved to 2 km per manuscript)
THIN_DISTANCE_KM <- 2

## Coordinate uncertainty threshold (GBIF CoordinateUncertaintyInMeters)
MAX_UNCERTAINTY_M <- 1000

## -- Paths ------------------------------------------------------------------

ROOT   <- here::here()
OUTDIR <- file.path(ROOT, "outputs")
dir.create(OUTDIR, recursive = TRUE, showWarnings = FALSE)

## -- Resolve inputs ----------------------------------------------------------

## Step 00 outputs — three thinned species CSVs (flat in outputs/ with 00_ prefix)
f_raw_hist_aeg <- resolve(
  "outputs/00_occ_raw_hist_aeg.csv",
  "MIH_Mosquitoes_Hawaii/outputs/00_occ_raw_hist_aeg.csv"
)

f_raw_mod_aeg <- resolve(
  "outputs/00_occ_raw_mod_aeg.csv",
  "MIH_Mosquitoes_Hawaii/outputs/00_occ_raw_mod_aeg.csv"
)

f_raw_mod_albo <- resolve(
  "outputs/00_occ_raw_mod_albo.csv",
  "MIH_Mosquitoes_Hawaii/outputs/00_occ_raw_mod_albo.csv"
)

## Step 01 output — environmental stack for ocean snapping validation (flat in outputs/ with 01_ prefix)
f_stack <- resolve(
  sprintf("outputs/01_env_stack_%s.tif", STACK),
  sprintf("MIH_Mosquitoes_Hawaii/outputs/01_env_stack_%s.tif", STACK)
)

## -- Load and prepare data ---------------------------------------------------

message(sprintf("Loading occurrence data and %s stack…", STACK))

occ_hist_aeg <- readr::read_csv(f_raw_hist_aeg, show_col_types = FALSE)
occ_mod_aeg  <- readr::read_csv(f_raw_mod_aeg, show_col_types = FALSE)
occ_mod_albo <- readr::read_csv(f_raw_mod_albo, show_col_types = FALSE)

## Load one layer from the stack to get its grid structure for snapping
## (all layers in a stack share the same grid; using the first layer is safe)
stack <- terra::rast(f_stack)
template_layer <- stack[[1]]

## Extract land cells (non-NA) as a matrix for snapping
land_cells <- terra::xyFromCell(template_layer, which(!is.na(terra::values(template_layer))))

message(sprintf("Loaded %d/%d/%d occurrence records (hist_aeg/mod_aeg/mod_albo)",
                nrow(occ_hist_aeg), nrow(occ_mod_aeg), nrow(occ_mod_albo)))

## -- Helper: snap coordinates to nearest land cell -----------------------

## Snap a coordinate (lon, lat) to the nearest land cell centroid via squared
## Euclidean distance. Returns c(snapped_lon, snapped_lat, distance_km).
snap_to_land <- function(lon, lat, land_cells, template_layer) {
  pt <- c(lon, lat)
  ## Squared Euclidean distance in degrees (approximation; good enough for Hawaii)
  sq_dist <- colSums((t(land_cells) - pt)^2)
  nearest_idx <- which.min(sq_dist)
  snapped <- land_cells[nearest_idx, ]
  ## Approximate km distance at Hawaii latitude (~20°N): 1 degree ≈ 111 km
  dist_km <- sqrt(sq_dist[nearest_idx]) * 111
  c(snapped[1], snapped[2], dist_km)
}

## -- Helper: QC and snap single dataset -----------------------------------

qc_and_snap <- function(df, species_name, land_cells, template_layer,
                        max_unc_m = 1000) {
  n_input <- nrow(df)
  
  ## Remove GBIF records with coordinate uncertainty > threshold
  if ("coordinateUncertaintyInMeters" %in% colnames(df)) {
    df <- df %>%
      dplyr::filter(is.na(coordinateUncertaintyInMeters) | 
                    coordinateUncertaintyInMeters <= max_unc_m)
  }
  
  n_after_unc <- nrow(df)
  
  ## Remove exact duplicates (same lon/lat)
  df <- df %>%
    dplyr::distinct(lon, lat, .keep_all = TRUE)
  
  n_after_dup <- nrow(df)
  
  ## Snap coordinates that return NA from the env stack (ocean or masked cells)
  snap_log <- list()
  
  for (i in seq_len(nrow(df))) {
    coords <- terra::extract(template_layer, cbind(df$lon[i], df$lat[i]))
    if (is.na(coords[1])) {
      ## This point is ocean/masked — snap to nearest land
      snapped <- snap_to_land(df$lon[i], df$lat[i], land_cells, template_layer)
      snap_log[[i]] <- data.frame(
        idx = i,
        before_lon = df$lon[i],
        before_lat = df$lat[i],
        after_lon = snapped[1],
        after_lat = snapped[2],
        snap_dist_km = snapped[3],
        reason = "ocean/masked"
      )
      df$lon[i] <- snapped[1]
      df$lat[i] <- snapped[2]
    }
  }
  
  snap_df <- if (length(snap_log) > 0) {
    do.call(rbind, snap_log)
  } else {
    data.frame(idx = integer(0), before_lon = numeric(0), before_lat = numeric(0),
               after_lon = numeric(0), after_lat = numeric(0), snap_dist_km = numeric(0),
               reason = character(0))
  }
  
  list(
    occ = df,
    snap_log = snap_df,
    counts = list(
      input = n_input,
      after_uncertainty = n_after_unc,
      after_duplicates = n_after_dup,
      snapped = nrow(snap_df)
    )
  )
}

## ── 2. QC and snap all three datasets -----------------------------------

message("QC and snapping…")

result_hist_aeg <- qc_and_snap(occ_hist_aeg, "hist_aeg", land_cells, template_layer,
                               max_unc_m = MAX_UNCERTAINTY_M)
result_mod_aeg  <- qc_and_snap(occ_mod_aeg, "mod_aeg", land_cells, template_layer,
                               max_unc_m = MAX_UNCERTAINTY_M)
result_mod_albo <- qc_and_snap(occ_mod_albo, "mod_albo", land_cells, template_layer,
                               max_unc_m = MAX_UNCERTAINTY_M)

snap_log_all <- rbind(
  cbind(species = "hist_aeg", result_hist_aeg$snap_log),
  cbind(species = "mod_aeg", result_mod_aeg$snap_log),
  cbind(species = "mod_albo", result_mod_albo$snap_log)
)

message(sprintf("QC complete. Snapped %d total records across all species.",
                nrow(snap_log_all)))

## ── 3. Spatial thinning via grid-based sampling -----------------------------

message(sprintf("Spatial thinning (%d km, grid-based)…", THIN_DISTANCE_KM))

thin_dataset <- function(df, thin_km, species_name, template_layer) {
  if (nrow(df) == 0) {
    return(df)
  }
  
  message(sprintf("  %s: starting with %d records", species_name, nrow(df)))
  
  ## Convert km to degrees (rough: 1 degree ≈ 111 km at Hawaii's latitude)
  thin_degrees <- thin_km / 111
  message(sprintf("    Thin distance: %f degrees (~%d km)", thin_degrees, thin_km))
  
  ## Get grid boundaries from template raster
  ext <- terra::ext(template_layer)
  message(sprintf("    Raster extent: lon [%.2f, %.2f], lat [%.2f, %.2f]",
                  ext$xmin, ext$xmax, ext$ymin, ext$ymax))
  
  ## Assign each point to a grid cell using coordinate-based math
  ## Grid cell ID = (row, col) based on dividing the extent by thin_degrees
  message(sprintf("    Assigning %d points to grid cells…", nrow(df)))
  
  df <- df %>%
    dplyr::mutate(
      grid_col = floor((lon - ext$xmin) / thin_degrees),
      grid_row = floor((lat - ext$ymin) / thin_degrees),
      grid_cell = paste0("R", grid_row, "_C", grid_col)
    )
  
  unique_cells <- length(unique(df$grid_cell))
  message(sprintf("    Assigned to %d unique grid cells", unique_cells))
  
  ## Sample one random record per grid cell
  message(sprintf("    Sampling one record per cell…"))
  result <- df %>%
    dplyr::group_by(grid_cell) %>%
    dplyr::slice_sample(n = 1) %>%
    dplyr::ungroup() %>%
    dplyr::select(-grid_col, -grid_row, -grid_cell)
  
  message(sprintf("  %s: %d -> %d records (%.1f%% retained)",
                  species_name, nrow(df), nrow(result),
                  100 * nrow(result) / nrow(df)))
  
  result
}

occ_hist_aeg_thin <- thin_dataset(result_hist_aeg$occ, THIN_DISTANCE_KM, "hist_aeg", template_layer)
occ_mod_aeg_thin  <- thin_dataset(result_mod_aeg$occ, THIN_DISTANCE_KM, "mod_aeg", template_layer)
occ_mod_albo_thin <- thin_dataset(result_mod_albo$occ, THIN_DISTANCE_KM, "mod_albo", template_layer)

## ── 4. Write outputs -------------------------------------------------------

message("Writing outputs…")

## Thinned occurrence CSVs (flat outputs/ with 02_ prefix)
out_hist_aeg <- file.path(OUTDIR, "02_occ_hist_aeg_thinned.csv")
out_mod_aeg  <- file.path(OUTDIR, "02_occ_mod_aeg_thinned.csv")
out_mod_albo <- file.path(OUTDIR, "02_occ_mod_albo_thinned.csv")

readr::write_csv(occ_hist_aeg_thin, out_hist_aeg)
readr::write_csv(occ_mod_aeg_thin, out_mod_aeg)
readr::write_csv(occ_mod_albo_thin, out_mod_albo)

## Ocean snap log (flat outputs/ with 02_ prefix)
out_snap_log <- file.path(OUTDIR, "02_occ_snap_log.txt")
if (nrow(snap_log_all) > 0) {
  sink(out_snap_log)
  cat(sprintf("Ocean snap log — coordinates snapped to nearest land cell\n"))
  cat(sprintf("Stack: %s\n", STACK))
  cat(sprintf("Total snapped: %d\n\n", nrow(snap_log_all)))
  print(snap_log_all)
  sink()
} else {
  writeLines("No coordinates required snapping.\n", out_snap_log)
}

## Thinning summary (flat outputs/ with 02_ prefix)
out_thin_summary <- file.path(OUTDIR, "02_thinning_summary.txt")
sink(out_thin_summary)

cat(sprintf("Thinning summary — grid-based spatial thinning\n"))
cat(sprintf("Stack: %s\n", STACK))
cat(sprintf("Thinning resolution: %d km\n", THIN_DISTANCE_KM))
cat(sprintf("Method: one random record per grid cell\n\n"))

cat("Historic A. aegypti:\n")
cat(sprintf("  Before thinning: %d\n", nrow(result_hist_aeg$occ)))
cat(sprintf("  After thinning:  %d\n", nrow(occ_hist_aeg_thin)))
cat(sprintf("  Retained: %.1f%%\n\n", 100 * nrow(occ_hist_aeg_thin) / nrow(result_hist_aeg$occ)))

cat("Modern A. aegypti:\n")
cat(sprintf("  Before thinning: %d\n", nrow(result_mod_aeg$occ)))
cat(sprintf("  After thinning:  %d\n", nrow(occ_mod_aeg_thin)))
cat(sprintf("  Retained: %.1f%%\n\n", 100 * nrow(occ_mod_aeg_thin) / nrow(result_mod_aeg$occ)))

cat("Modern A. albopictus:\n")
cat(sprintf("  Before thinning: %d\n", nrow(result_mod_albo$occ)))
cat(sprintf("  After thinning:  %d\n", nrow(occ_mod_albo_thin)))
cat(sprintf("  Retained: %.1f%%\n\n", 100 * nrow(occ_mod_albo_thin) / nrow(result_mod_albo$occ)))

cat("QC summary (before thinning):\n")
cat(sprintf("  Hist aeg: %d input -> %d (uncertainty) -> %d (dedup) -> snapped %d\n",
            result_hist_aeg$counts$input,
            result_hist_aeg$counts$after_uncertainty,
            result_hist_aeg$counts$after_duplicates,
            result_hist_aeg$counts$snapped))
cat(sprintf("  Mod aeg:  %d input -> %d (uncertainty) -> %d (dedup) -> snapped %d\n",
            result_mod_aeg$counts$input,
            result_mod_aeg$counts$after_uncertainty,
            result_mod_aeg$counts$after_duplicates,
            result_mod_aeg$counts$snapped))
cat(sprintf("  Mod albo: %d input -> %d (uncertainty) -> %d (dedup) -> snapped %d\n",
            result_mod_albo$counts$input,
            result_mod_albo$counts$after_uncertainty,
            result_mod_albo$counts$after_duplicates,
            result_mod_albo$counts$snapped))

sink()

message(sprintf("Step 02 complete. Outputs at %s", OUTDIR))

## ── 5. Push to Drive --------------------------------------------------------

options(mih.push = TRUE)

push_output(out_hist_aeg, "outputs/02_occ_hist_aeg_thinned.csv")
push_output(out_mod_aeg, "outputs/02_occ_mod_aeg_thinned.csv")
push_output(out_mod_albo, "outputs/02_occ_mod_albo_thinned.csv")
push_output(out_snap_log, "outputs/02_occ_snap_log.txt")
push_output(out_thin_summary, "outputs/02_thinning_summary.txt")

message("Done.")
