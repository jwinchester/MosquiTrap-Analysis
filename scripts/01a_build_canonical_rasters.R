## scripts/01a_build_canonical_rasters.R
##
## Build the canonical DEM and island-index rasters for Hawaii at the shared
## 250 m HCDP grid. Three loose outputs to data/public/:
##
##   01_DEM_hawaii_statewide_canonical.tif  (FLT4S; 0 ocean, elev m on land)
##   01_island_index.tif                    (INT1U; 0 ocean, 1..7 islands)
##   canonical_rasters_summary.csv          (per-island n_cells / area / elev)
##
## Inputs:
##   USGS 3DEP 1/3 arc-second NED tiles (direct S3 GET, 404 = ocean cell)
##   data/public/01_HCDP_rainfall_month_2002_2011.zip (one month = footprint)
##
## Rationale: PIPELINE_SPEC "Sub-step 01a"; PROVENANCE "Canonical coastline
## and DEM". Idempotent: exits without rebuild when outputs already exist on
## the expected grid; delete any output to force a rebuild.

library(here)
library(conflicted)
library(googledrive)
library(terra)

conflicts_prefer(terra::extract, base::intersect, base::setdiff)

source(here::here("scripts/_pipeline_boilerplate.R"))
options(mih.push = TRUE)

## Defensive timeout bump in case any fallback path hits base R's download
## chain; curl::multi_download below has its own transfer policy.
options(timeout = max(3600, getOption("timeout")))

if (!requireNamespace("curl", quietly = TRUE)) {
  stop("Package 'curl' is required for NED tile downloads. ",
       "install.packages('curl')")
}

## ----- Constants ------------------------------------------------------------

DATA_PUBLIC <- here::here("data/public")
RAW_DIR     <- file.path(DATA_PUBLIC, "raw/ned_13as_hawaii")

DEM_OUT  <- file.path(DATA_PUBLIC, "01_DEM_hawaii_statewide_canonical.tif")
IDX_OUT  <- file.path(DATA_PUBLIC, "01_island_index.tif")
SUMM_OUT <- file.path(DATA_PUBLIC, "canonical_rasters_summary.csv")

## Shared 250 m HCDP grid (PIPELINE_SPEC, top of Step 01). 1520 x 2288, WGS84.
HCDP_XMIN <- -159.816
HCDP_XMAX <- -154.668
HCDP_YMIN <-   18.849
HCDP_YMAX <-   22.269
HCDP_RES  <- 0.00225

S3_BASE <- "https://prd-tnm.s3.amazonaws.com/StagedProducts/Elevation/13/TIFF/current"

## Minimum patch size to count as a main island. 30 km^2 at 250 m resolution
## is 30e6 / 250^2 = 480 cells. Drops islets and coastal detritus; keeps the
## seven main islands (smallest: Kahoolawe ~115 km^2).
MIN_ISLAND_CELLS <- 480L

## Canonical island centroids in degrees. Rough is fine -- each main island
## is closer to its own canonical centroid than any other by a wide margin,
## so the nearest-centroid rule is stable.
ISLAND_REF <- data.frame(
  code = 1:7,
  name = c("Hawaii", "Maui", "Oahu", "Kauai", "Molokai", "Lanai", "Kahoolawe"),
  lon  = c(-155.50, -156.30, -157.98, -159.50, -157.00, -156.92, -156.60),
  lat  = c(  19.60,   20.80,   21.48,   22.08,   21.13,   20.83,   20.55),
  stringsAsFactors = FALSE
)

## ----- Idempotency ----------------------------------------------------------

outputs_fresh <- function() {
  if (!all(file.exists(c(DEM_OUT, IDX_OUT, SUMM_OUT)))) return(FALSE)
  dem <- tryCatch(terra::rast(DEM_OUT), error = function(e) NULL)
  if (is.null(dem)) return(FALSE)
  res_ok <- all(abs(terra::res(dem) - HCDP_RES) < 1e-9)
  e      <- as.vector(terra::ext(dem))
  ext_ok <- all(abs(e - c(HCDP_XMIN, HCDP_XMAX, HCDP_YMIN, HCDP_YMAX)) < 1e-6)
  res_ok && ext_ok
}

if (outputs_fresh()) {
  message("01a: outputs already present on expected grid; ",
          "delete any output to force rebuild.")
} else {
  
  ## ----- 1. Enumerate + download NED tiles ------------------------------------
  
  dir.create(RAW_DIR, recursive = TRUE, showWarnings = FALSE)
  
  ## The twelve USGS 3DEP 1/3 arc-second tiles that cover the Hawaiian
  ## Islands. Hawaii doesn't move, so this is the list -- no geometric
  ## enumeration, no silent-ocean-skip dance. A non-200 HEAD on any of
  ## these means either the S3 URL pattern has changed or the bucket is
  ## having a moment; either way it's an error, not a normal case.
  TILES <- c("n19w156",  # South Point (Big Island south tip)
             "n20w155",  # Puna (Big Island east)
             "n20w156",  # central Big Island
             "n20w157",  # Kona (Big Island west, sliver)
             "n21w156",  # Kohala + east Maui
             "n21w157",  # west Maui, Lanai, Kahoolawe, SE Molokai
             "n21w158",  # Lanai west sliver
             "n22w157",  # north Molokai
             "n22w158",  # Oahu
             "n22w159",  # Kaena Point (Oahu, sliver)
             "n22w160",  # south Kauai
             "n23w160")  # north Kauai
  
  urls      <- file.path(S3_BASE, TILES, sprintf("USGS_13_%s.tif", TILES))
  destfiles <- file.path(RAW_DIR,         sprintf("USGS_13_%s.tif", TILES))
  
  ## HEAD each tile to get expected Content-Length. Size-match on disk is
  ## what tells us a file is complete; we do NOT rely on status_code from
  ## the later multi_download call (curl + resume=TRUE on an already-
  ## complete file fires Range: bytes=N- at offset N==filesize and S3
  ## returns 416 Requested Range Not Satisfiable, which is not an error).
  probe_size <- function(u) {
    h <- curl::new_handle(nobody = TRUE, connecttimeout = 30L, timeout = 60L)
    r <- curl::curl_fetch_memory(u, handle = h)
    if (r$status_code != 200L) {
      stop(sprintf("HEAD returned %d for %s\n  S3 URL pattern may have changed.",
                   r$status_code, u))
    }
    hd <- curl::parse_headers_list(r$headers)
    as.numeric(hd[["content-length"]])
  }
  
  message("01a: checking ", length(TILES), " NED tiles against S3")
  sizes <- vapply(urls, probe_size, numeric(1))
  
  on_disk  <- file.exists(destfiles)
  disk_sz  <- ifelse(on_disk, file.info(destfiles)$size, NA_real_)
  needs_dl <- !on_disk | is.na(disk_sz) | disk_sz != sizes
  
  message(sprintf("01a: %d cached, %d to download",
                  sum(!needs_dl), sum(needs_dl)))
  
  if (any(needs_dl)) {
    res <- curl::multi_download(
      urls      = urls[needs_dl],
      destfiles = destfiles[needs_dl],
      resume    = TRUE,
      progress  = TRUE
    )
    got_size <- file.info(res$destfile)$size
    bad_dl   <- !res$success | is.na(got_size) | got_size != sizes[needs_dl]
    if (any(bad_dl)) {
      stop("Downloads incomplete for: ",
           paste(basename(res$destfile[bad_dl]), collapse = ", "),
           "; re-run to resume.")
    }
  }
  
  ## terra smoke check guards against filesystem-level corruption that
  ## slipped past the size-match test.
  land_tiles <- destfiles
  bad_read <- vapply(land_tiles, function(p) {
    inherits(try(terra::rast(p), silent = TRUE), "try-error")
  }, logical(1))
  if (any(bad_read)) {
    unlink(land_tiles[bad_read])
    stop("Tiles fail terra::rast read: ",
         paste(basename(land_tiles[bad_read]), collapse = ", "),
         "; re-run to refetch.")
  }
  
  ## ----- 2. Mosaic + reproject + resample to HCDP grid -----------------------
  
  message("01a: mosaicking and projecting to HCDP grid")
  
  tile_rasts <- lapply(land_tiles, terra::rast)
  if (length(tile_rasts) == 1L) {
    mos <- tile_rasts[[1]]
  } else {
    mos <- terra::mosaic(terra::sprc(tile_rasts), fun = "mean")
  }
  
  hcdp_template <- terra::rast(
    ext        = terra::ext(HCDP_XMIN, HCDP_XMAX, HCDP_YMIN, HCDP_YMAX),
    resolution = HCDP_RES,
    crs        = "EPSG:4326"
  )
  
  ## project() handles the NAD83 -> WGS84 transform together with the
  ## resolution change in one pass; sub-meter at this latitude vs a 250 m
  ## target, but the explicit reproject keeps the CRS lineage clean.
  dem_target <- terra::project(mos, hcdp_template, method = "bilinear")
  
  ## ----- 3. Canonical land mask + final DEM -----------------------------------
  
  message("01a: building canonical land mask")
  
  ## One month of HCDP rainfall suffices; the Lucas et al. 2022 product has
  ## identical land footprint across all months.
  rainfall_zip <- resolve(
    local_path = "data/public/01_HCDP_rainfall_month_2002_2011.zip",
    drive_path = "MIH_Mosquitoes_Hawaii/data/public/01_HCDP_rainfall_month_2002_2011.zip",
    validate   = function(p) {
      file.info(p)$size > 1e8 && nrow(utils::unzip(p, list = TRUE)) > 0L
    }
  )
  zip_entries <- utils::unzip(rainfall_zip, list = TRUE)$Name
  rain_tif    <- grep("rainfall_new_month_statewide_data_map_.*\\.tif$",
                      zip_entries, value = TRUE)[1]
  if (is.na(rain_tif)) stop("No rainfall TIF found inside ", rainfall_zip)
  rain_one <- terra::rast(sprintf("/vsizip/%s/%s", rainfall_zip, rain_tif))
  
  ## Rainfall is already on the HCDP grid by construction; defensive resample
  ## is a no-op for the expected input. compareGeom returns FALSE on any
  ## header mismatch (crs, extent, resolution) and triggers the realign.
  if (!terra::compareGeom(rain_one, hcdp_template, stopOnError = FALSE)) {
    rain_one <- terra::resample(rain_one, hcdp_template, method = "near")
  }
  
  ## Intersection mask: both (3DEP > 0) AND HCDP-rainfall-non-NA must agree.
  ## Explicit !is.na(dem_target) keeps land_mask strictly TRUE/FALSE rather
  ## than propagating NA from cells outside NED tile coverage.
  land_mask <- !is.na(dem_target) & dem_target > 0 & !is.na(rain_one)
  
  ## Canonical DEM: elevation on land, 0 on ocean. No NA cells in the output.
  dem_canon <- terra::ifel(land_mask, dem_target, 0)
  
  ## ----- 4. Island index via connected components -----------------------------
  
  message("01a: computing island index")
  
  ## 1/NA numeric raster for unambiguous patch input.
  land_numeric <- terra::ifel(land_mask, 1L, NA)
  patches      <- terra::patches(land_numeric, directions = 8)
  
  ## Patch cell counts; keep only patches >= 30 km^2.
  pf      <- terra::freq(patches)
  pf      <- pf[!is.na(pf$value), , drop = FALSE]
  big_ids <- pf$value[pf$count >= MIN_ISLAND_CELLS]
  if (length(big_ids) != 7L) {
    stop(sprintf("Expected 7 island patches >= %d cells; found %d. ",
                 MIN_ISLAND_CELLS, length(big_ids)),
         "Either the land mask has changed or the threshold needs revision.")
  }
  
  ## Centroid per big patch: restrict raster to big ids, polygonise-dissolve,
  ## then centroid. dissolve=TRUE yields one polygon per unique patch id.
  patches_big <- terra::ifel(patches %in% big_ids, patches, NA)
  poly        <- terra::as.polygons(patches_big, dissolve = TRUE, na.rm = TRUE)
  names(poly)[1] <- "patch_id"
  cent_xy <- terra::crds(terra::centroids(poly))
  
  ## Nearest canonical centroid wins.
  assign_to_island <- function(xy) {
    d2 <- (ISLAND_REF$lon - xy[1])^2 + (ISLAND_REF$lat - xy[2])^2
    ISLAND_REF$code[which.min(d2)]
  }
  poly$island_code <- vapply(
    seq_len(nrow(cent_xy)),
    function(i) assign_to_island(cent_xy[i, ]),
    integer(1)
  )
  
  if (anyDuplicated(poly$island_code) || !setequal(poly$island_code, 1:7)) {
    stop("Island assignment failed: patch-to-code mapping is not 1:1 over 1..7.")
  }
  
  ## Remap patches -> island codes. classify() with others=NA leaves non-big
  ## patches and ocean as NA; final ifel forces 0 on ocean/detritus.
  rcl        <- cbind(poly$patch_id, poly$island_code)
  island_idx <- terra::classify(patches, rcl, others = NA)
  island_idx <- terra::as.int(terra::ifel(is.na(island_idx), 0L, island_idx))
  
  ## ----- 5. Write outputs -----------------------------------------------------
  
  message("01a: writing outputs")
  
  dir.create(DATA_PUBLIC, recursive = TRUE, showWarnings = FALSE)
  
  terra::writeRaster(
    dem_canon, DEM_OUT,
    datatype  = "FLT4S",
    gdal      = c("COMPRESS=DEFLATE", "PREDICTOR=3", "TILED=YES"),
    overwrite = TRUE
  )
  
  terra::writeRaster(
    island_idx, IDX_OUT,
    datatype  = "INT1U",
    gdal      = c("COMPRESS=DEFLATE", "TILED=YES"),
    overwrite = TRUE
  )
  
  ## Per-island summary. One-pass over values() keeps memory flat.
  idx_vals <- as.vector(terra::values(island_idx))
  dem_vals <- as.vector(terra::values(dem_canon))
  CELL_KM2 <- (250 / 1000)^2  # 0.0625 km^2 per 250 m cell
  
  summary_df <- do.call(rbind, lapply(1:7, function(code) {
    sel  <- idx_vals == code
    elev <- dem_vals[sel]
    elev <- elev[!is.na(elev) & elev > 0]
    data.frame(
      island_code   = code,
      island_name   = ISLAND_REF$name[ISLAND_REF$code == code],
      n_cells       = sum(sel, na.rm = TRUE),
      area_km2      = round(sum(sel, na.rm = TRUE) * CELL_KM2, 2),
      elev_min_m    = round(min(elev), 1),
      elev_median_m = round(stats::median(elev), 1),
      elev_max_m    = round(max(elev), 1),
      stringsAsFactors = FALSE
    )
  }))
  utils::write.csv(summary_df, SUMM_OUT, row.names = FALSE)
  
  ## ----- 6. Push to Drive -----------------------------------------------------
  
  push_output(DEM_OUT,  "data/public/01_DEM_hawaii_statewide_canonical.tif")
  push_output(IDX_OUT,  "data/public/01_island_index.tif")
  push_output(SUMM_OUT, "data/public/canonical_rasters_summary.csv")
  
  message("01a: done")
  message(sprintf("  %d cells across 7 islands, %.0f km^2 total land",
                  sum(summary_df$n_cells), sum(summary_df$area_km2)))
  
}  # end !outputs_fresh branch