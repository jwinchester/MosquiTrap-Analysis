## 00_occurrence.R — Fetch, stage, and document all species occurrence records
## MIH Pipeline Step 00
## ────────────────────────────────────────────────────────────────────────────

library(here)
library(conflicted)
library(googledrive)
library(readxl)
library(readr)
library(dplyr)
library(stringr)

source(here::here("scripts/_pipeline_boilerplate.R"))

conflicts_prefer(dplyr::filter, dplyr::lag, dplyr::select,
                 base::intersect, base::setdiff)

## -- Paths ------------------------------------------------------------------

ROOT   <- here::here()
OUTDIR <- file.path(ROOT, "outputs")
dir.create(OUTDIR, recursive = TRUE, showWarnings = FALSE)

## -- Resolve all inputs -----------------------------------------------------

## Field data — tiers 1 and 2 only (never re-downloaded from web)
f_ayas   <- resolve("data/field/allyears_allspp_pres_maxent.csv",
                     "MIH_Mosquitoes_Hawaii/data/field/allyears_allspp_pres_maxent.csv")
f_1966   <- resolve("data/field/1966_aegypti_presence.csv",
                     "MIH_Mosquitoes_Hawaii/data/field/1966_aegypti_presence.csv")
f_2002a  <- resolve("data/field/2002_aegypti_presence.csv",
                     "MIH_Mosquitoes_Hawaii/data/field/2002_aegypti_presence.csv")
f_doh    <- resolve("data/field/2002_DOH.csv",
                     "MIH_Mosquitoes_Hawaii/data/field/2002_DOH.csv")
f_mtr    <- resolve("data/field/mtr.csv",
                     "MIH_Mosquitoes_Hawaii/data/field/mtr.csv")
f_sites  <- resolve("data/field/sitedata.xls",
                     "MIH_Mosquitoes_Hawaii/data/field/sitedata.xls")

## Public data — all three tiers
## rgbif downloads by raw key name; fetch_fn renames to spec name and cleans up.
f_gbif_albo <- resolve(
  "data/public/00_GBIF_albopictus_0009417.zip",
  "MIH_Mosquitoes_Hawaii/data/public/00_GBIF_albopictus_0009417.zip",
  fetch_fn = function(path) {
    if (!requireNamespace("rgbif", quietly = TRUE))
      stop("rgbif required — install.packages('rgbif')")
    raw_name <- file.path(dirname(path), "0009417-260409193756587.zip")
    rgbif::occ_download_get(key = "0009417-260409193756587",
                            path = dirname(path), overwrite = TRUE)
    file.rename(raw_name, path)
    unlink(raw_name)
  },
  validate = function(path) file.size(path) > 1000
)

f_gbif_aeg <- resolve(
  "data/public/00_GBIF_aegypti_0009420.zip",
  "MIH_Mosquitoes_Hawaii/data/public/00_GBIF_aegypti_0009420.zip",
  fetch_fn = function(path) {
    if (!requireNamespace("rgbif", quietly = TRUE))
      stop("rgbif required — install.packages('rgbif')")
    raw_name <- file.path(dirname(path), "0009420-260409193756587.zip")
    rgbif::occ_download_get(key = "0009420-260409193756587",
                            path = dirname(path), overwrite = TRUE)
    file.rename(raw_name, path)
    unlink(raw_name)
  },
  validate = function(path) file.size(path) > 1000
)

## iNat — pending, optional for this step (required for Step 04)
f_inat <- tryCatch(
  resolve("data/public/00_inat_mosquitoes_hawaii.csv",
          "MIH_Mosquitoes_Hawaii/data/public/00_inat_mosquitoes_hawaii.csv"),
  error = function(e) {
    cat("FLAG -- iNat export not available yet (required before submission)\n")
    NULL
  }
)

## ── 1. allyears_allspp_pres_maxent.csv (primary compiled dataset) ──────────

ayas <- readr::read_csv(f_ayas, show_col_types = FALSE)

ayas_parsed <- ayas %>%
  dplyr::mutate(
    species = dplyr::case_when(
      species %in% c("aegypti_1966")  ~ "aegypti",
      species %in% c("aegypti_21")    ~ "aegypti",
      species %in% c("albopictus_21") ~ "albopictus",
      TRUE ~ NA_character_
    ),
    period = dplyr::case_when(
      grepl("1966", ayas$species) ~ "historical",
      TRUE                        ~ "modern"
    ),
    lon      = longitude,
    lat      = latitude,
    source   = data.source,
    year     = as.integer(date),
    location = location.name,
    notes    = NA_character_
  ) %>%
  dplyr::filter(!is.na(species)) %>%
  dplyr::select(species, lon, lat, source, year, location, notes, period)

ayas_hist_aeg  <- dplyr::filter(ayas_parsed, species == "aegypti", period == "historical")
ayas_mod_aeg   <- dplyr::filter(ayas_parsed, species == "aegypti", period == "modern")
ayas_mod_albo  <- dplyr::filter(ayas_parsed, species == "albopictus", period == "modern")

cat("AYAS historical aegypti:", nrow(ayas_hist_aeg), "\n")
cat("AYAS modern aegypti:", nrow(ayas_mod_aeg), "\n")
cat("AYAS modern albopictus:", nrow(ayas_mod_albo), "\n")

## ── 2. 1966_aegypti_presence.csv ───────────────────────────────────────────

hist_1966 <- readr::read_csv(f_1966, show_col_types = FALSE) %>%
  dplyr::transmute(
    species  = "aegypti",
    lon      = long,
    lat      = lat,
    source   = "AAEP_1966_raw",
    year     = 1966L,
    location = stringr::str_trim(name),
    notes    = "higher-precision coords than AYAS; Big Island only",
    period   = "historical"
  )

cat("1966 raw (Big Island, hi-precision):", nrow(hist_1966), "\n")

## ── 3. 2002_aegypti_presence.csv ───────────────────────────────────────────

mod_aeg_2002 <- readr::read_csv(f_2002a, show_col_types = FALSE) %>%
  dplyr::transmute(
    species  = "aegypti",
    lon      = lon,
    lat      = lat,
    source   = "DOH_2002_raw",
    year     = 2002L,
    location = stringr::str_trim(location),
    notes    = "higher-precision coords than AYAS",
    period   = "modern"
  )

cat("2002 DOH aegypti raw:", nrow(mod_aeg_2002), "\n")

## ── 4. 2002_DOH.csv — full 81-site survey ──────────────────────────────────
## Two trailing empty columns (trailing commas); one lat typo ("19-498");
## one NBSP (\u00a0) in a longitude value. Force character read so gsub and
## parse_number can work on raw strings before readr coerces to numeric.

doh_full <- suppressMessages(suppressWarnings(
  readr::read_csv(f_doh,
                  locale = readr::locale(encoding = "latin1"),
                  show_col_types = FALSE,
                  col_select = c(name2, aa, ae, long, lat),
                  col_types = readr::cols(long = "c", lat = "c")) %>%
  dplyr::mutate(
    ## captain cook upper has lat typo "19-498" → 19.498
    lat  = as.numeric(stringr::str_replace(lat, "^(\\d+)-(\\d+)$", "\\1.\\2")),
    ## kainaliu has NBSP (\u00a0) before its minus sign; gsub strips it,
    ## parse_number extracts the number
    long = readr::parse_number(gsub("\u00a0", " ", long))
  )
))

mod_albo_doh <- doh_full %>%
  dplyr::filter(aa == 1) %>%
  dplyr::transmute(
    species  = "albopictus",
    lon      = long,
    lat      = lat,
    source   = "DOH_2002_raw",
    year     = 2002L,
    location = stringr::str_trim(name2),
    notes    = "higher-precision coords than AYAS; Big Island only",
    period   = "modern"
  )

cat("2002 DOH albopictus raw:", nrow(mod_albo_doh), "\n")

## ── 5. MosquiTrap — site-level presence records ───────────────────────────

sitedata <- readxl::read_xls(f_sites, sheet = 1) %>%
  dplyr::transmute(
    site      = sitename,
    site_lat  = as.numeric(lat),
    site_lon  = as.numeric(long),
    elevation = elevation
  ) %>%
  dplyr::distinct(site, .keep_all = TRUE)

## Hardcoded coordinates for MTR sites missing from sitedata.xls.
## lyon    = Lyon Arboretum, Manoa, Oahu — parking lot area.
## spencer = Spencer Beach Park, near Kawaihae, Big Island.
sitedata <- dplyr::bind_rows(sitedata, tibble::tribble(
  ~site,     ~site_lat,  ~site_lon,    ~elevation,
  "lyon",     21.333,    -157.800,      120,
  "spencer",  20.023,    -155.822,        3
))

mtr <- readr::read_csv(f_mtr, show_col_types = FALSE)

mtr_site <- mtr %>%
  dplyr::group_by(site) %>%
  dplyr::summarise(
    n_traps    = dplyr::n(),
    aeg_total  = sum(aeg, na.rm = TRUE),
    alb_total  = sum(alb, na.rm = TRUE),
    aeg_pos    = aeg_total > 0,
    alb_pos    = alb_total > 0,
    inline_lat = if (all(is.na(lat))) NA_real_ else first(na.omit(lat)),
    inline_lon = if (all(is.na(long))) NA_real_ else first(na.omit(long)),
    .groups    = "drop"
  ) %>%
  dplyr::left_join(sitedata, by = "site") %>%
  dplyr::mutate(
    final_lat = dplyr::coalesce(site_lat, inline_lat),
    final_lon = dplyr::coalesce(site_lon, inline_lon)
  )

missing_coords <- dplyr::filter(mtr_site, is.na(final_lat))
if (nrow(missing_coords) > 0) {
  cat("FLAG -- MTR sites with NO coordinates (excluded from spatial outputs):\n")
  print(dplyr::select(missing_coords, site, n_traps, aeg_pos, alb_pos))
}

mtr_aeg <- mtr_site %>%
  dplyr::filter(aeg_pos, !is.na(final_lat)) %>%
  dplyr::transmute(
    species  = "aegypti",
    lon      = final_lon,
    lat      = final_lat,
    source   = "MTR_sitedata",
    year     = 2011L,
    location = site,
    notes    = paste0("n_traps=", n_traps, "; aeg_total=", aeg_total),
    period   = "modern"
  )

mtr_albo <- mtr_site %>%
  dplyr::filter(alb_pos, !is.na(final_lat)) %>%
  dplyr::transmute(
    species  = "albopictus",
    lon      = final_lon,
    lat      = final_lat,
    source   = "MTR_sitedata",
    year     = 2011L,
    location = site,
    notes    = paste0("n_traps=", n_traps, "; alb_total=", alb_total),
    period   = "modern"
  )

cat("MTR aegypti sites:", nrow(mtr_aeg), "\n")
cat("MTR albopictus sites:", nrow(mtr_albo), "\n")

## ── 6. GBIF ────────────────────────────────────────────────────────────────

read_gbif <- function(zipfile, sp_label) {
  ## Each extraction gets its own directory to prevent cross-contamination
  ## when both species zips contain identically-named occurrence.txt
  tmpdir <- tempfile(pattern = paste0("gbif_", sp_label, "_"))
  dir.create(tmpdir)
  on.exit(unlink(tmpdir, recursive = TRUE))

  unzip(zipfile, exdir = tmpdir)
  occ_file <- list.files(tmpdir, pattern = "occurrence",
                         full.names = TRUE, recursive = TRUE)
  if (length(occ_file) == 0) {
    occ_file <- list.files(tmpdir, pattern = "\\.csv$|\\.txt$",
                           full.names = TRUE, recursive = TRUE)
  }
  stopifnot(length(occ_file) >= 1)

  raw <- readr::read_tsv(occ_file[1], show_col_types = FALSE, guess_max = 5000)

  raw %>%
    dplyr::filter(!is.na(decimalLongitude), !is.na(decimalLatitude)) %>%
    dplyr::transmute(
      species  = sp_label,
      lon      = decimalLongitude,
      lat      = decimalLatitude,
      source   = paste0("GBIF_", dplyr::coalesce(institutionCode, "unknown")),
      year     = as.integer(year),
      location = locality,
      notes    = paste0("gbifID=", gbifID,
                        "; basisOfRecord=", basisOfRecord,
                        "; coordUncertainty_m=", coordinateUncertaintyInMeters),
      period   = NA_character_
    )
}

gbif_albo <- read_gbif(f_gbif_albo, "albopictus") %>%
  dplyr::mutate(period = "modern")

gbif_aeg <- read_gbif(f_gbif_aeg, "aegypti")

## Split aegypti by period: <=1970 historical, >=2000 modern, 1971-1999 excluded
gbif_aeg_hist <- dplyr::filter(gbif_aeg, !is.na(year), year <= 1970) %>%
  dplyr::mutate(period = "historical")
gbif_aeg_mod  <- dplyr::filter(gbif_aeg, is.na(year) | year >= 2000) %>%
  dplyr::mutate(period = "modern")
gbif_aeg_grey <- dplyr::filter(gbif_aeg, !is.na(year), year > 1970, year < 2000)

cat("GBIF albopictus:", nrow(gbif_albo), "\n")
cat("GBIF aegypti: hist=", nrow(gbif_aeg_hist),
    " mod=", nrow(gbif_aeg_mod),
    " excluded_1971-1999=", nrow(gbif_aeg_grey), "\n")

## ── 7. iNaturalist ────────────────────────────────────────────────────────

if (!is.null(f_inat)) {
  inat_raw <- readr::read_csv(f_inat, show_col_types = FALSE)
  cat("iNat file found:", nrow(inat_raw), "records -- staging for validation\n")
  readr::write_csv(inat_raw, file.path(OUTDIR, "00_occ_raw_inat.csv"))
  push_output(file.path(OUTDIR, "00_occ_raw_inat.csv"),
              "outputs/00_occ_raw_inat.csv")
}

## ── 8. Assemble outputs ───────────────────────────────────────────────────

occ_hist_aeg <- dplyr::bind_rows(ayas_hist_aeg, hist_1966, gbif_aeg_hist) %>%
  dplyr::select(-period) %>%
  dplyr::arrange(source, lon, lat)

occ_mod_aeg <- dplyr::bind_rows(ayas_mod_aeg, mod_aeg_2002, mtr_aeg, gbif_aeg_mod) %>%
  dplyr::select(-period) %>%
  dplyr::arrange(source, lon, lat)

occ_mod_albo <- dplyr::bind_rows(ayas_mod_albo, mod_albo_doh, mtr_albo, gbif_albo) %>%
  dplyr::select(-period) %>%
  dplyr::arrange(source, lon, lat)

## ── 9. Write outputs and push to Drive ────────────────────────────────────

out_hist <- file.path(OUTDIR, "00_occ_raw_hist_aeg.csv")
out_maeg <- file.path(OUTDIR, "00_occ_raw_mod_aeg.csv")
out_malb <- file.path(OUTDIR, "00_occ_raw_mod_albo.csv")
out_summ <- file.path(OUTDIR, "00_occurrence_summary.txt")

readr::write_csv(occ_hist_aeg, out_hist)
readr::write_csv(occ_mod_aeg,  out_maeg)
readr::write_csv(occ_mod_albo, out_malb)

push_output(out_hist, "outputs/00_occ_raw_hist_aeg.csv")
push_output(out_maeg, "outputs/00_occ_raw_mod_aeg.csv")
push_output(out_malb, "outputs/00_occ_raw_mod_albo.csv")

cat("\nOutputs written to", OUTDIR, "\n")

## ── 10. Summary ───────────────────────────────────────────────────────────

fmt_src <- function(df) {
  df %>% dplyr::count(source) %>%
    dplyr::mutate(line = sprintf("    %s: %d", source, n)) %>% dplyr::pull(line)
}

summary_lines <- c(
  "MIH Pipeline -- Step 00 Occurrence Summary",
  paste("Generated:", Sys.time()),
  "",
  "--- HISTORICAL AEGYPTI ---",
  sprintf("  Total: %d records (pre-dedup)", nrow(occ_hist_aeg)),
  fmt_src(occ_hist_aeg),
  "",
  "--- MODERN AEGYPTI ---",
  sprintf("  Total: %d records (pre-dedup)", nrow(occ_mod_aeg)),
  fmt_src(occ_mod_aeg),
  "",
  "--- MODERN ALBOPICTUS ---",
  sprintf("  Total: %d records (pre-dedup)", nrow(occ_mod_albo)),
  fmt_src(occ_mod_albo),
  "",
  "--- FLAGS ---",
  if (nrow(missing_coords) > 0)
    paste0("  * MTR sites missing coordinates (need for Step 06): ",
           paste(missing_coords$site, collapse = ", ")),
  if (nrow(gbif_aeg_grey) > 0)
    sprintf("  * GBIF aegypti 1971-1999: %d records excluded (displacement transition)",
            nrow(gbif_aeg_grey)),
  if (is.null(f_inat))
    "  * iNat export: NOT YET AVAILABLE (required for Step 04 validation)"
)

writeLines(summary_lines, out_summ)
push_output(out_summ, "outputs/00_occurrence_summary.txt")

cat("\n", paste(summary_lines, collapse = "\n"), "\n")
cat("\nStep 00 complete.\n")
