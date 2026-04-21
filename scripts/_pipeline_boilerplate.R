## scripts/_pipeline_boilerplate.R
##
## Single source of truth for the MIH pipeline's shared infrastructure:
##   - DRIVE_ROOT, DRIVE_AUTH constants
##   - resolve()     : three-tier file resolution (local → Drive → fetch_fn)
##   - push_output() : gated Drive upload with update-if-exists logic
##
## Sourced from every pipeline script and utility. Do not copy this file's
## contents into other scripts — source() it instead, so boilerplate fixes
## propagate automatically.
##
## Usage from a pipeline script:
##
##   library(here)
##   library(googledrive)
##   # ... other packages ...
##
##   source(here::here("scripts/_pipeline_boilerplate.R"))
##
## That's the entire boilerplate. No caller-side flag variables required.
##
## Two options control behaviour — set them before calling resolve() or
## push_output() if the defaults don't fit:
##
##   options(mih.push = FALSE)             # disable Drive uploads (default TRUE)
##   options(mih.resolve.verbose = FALSE)  # silence per-hit messages (default TRUE)
##
## The options are read at call time, so per-script overrides take effect
## immediately without re-sourcing this file.
## ----------------------------------------------------------------------------

DRIVE_ROOT <- "MIH_Mosquitoes_Hawaii"
DRIVE_AUTH <- "jwin74@gmail.com"

resolve <- function(local_path, drive_path = NULL, fetch_fn = NULL,
                    validate = NULL) {
  verbose <- isTRUE(getOption("mih.resolve.verbose", default = TRUE))
  
  ## Resolve local_path against the project root. `here::here()` walks up
  ## from R's current working directory to find the `.here` sentinel and
  ## returns the absolute project-root path. Idempotent on absolute paths
  ## (no-op if an absolute path is passed), so call sites stay identical
  ## whether they pass relative or absolute. This fixes a class of bug
  ## where scripts invoked via `Rscript` from `scripts/` treated relative
  ## paths as scripts-relative rather than project-relative, silently
  ## triggering re-downloads and dumping files into `scripts/data/`.
  local_path <- here::here(local_path)
  
  ## Tier 1: local. If validate() is supplied, a local hit that fails
  ## validation is treated as absent and resolution falls through to
  ## tier 2, then tier 3. This handles interrupted downloads and
  ## corrupted caches without requiring manual cleanup.
  valid_local <- function(path) {
    if (!file.exists(path)) return(FALSE)
    if (is.null(validate))  return(TRUE)
    isTRUE(tryCatch(validate(path), error = function(e) FALSE))
  }
  
  if (valid_local(local_path)) return(local_path)
  
  if (!is.null(drive_path)) {
    googledrive::drive_auth(email = DRIVE_AUTH)
    hit <- tryCatch(googledrive::drive_get(drive_path), error = function(e) NULL)
    if (!is.null(hit) && nrow(hit) > 0) {
      dir.create(dirname(local_path), recursive = TRUE, showWarnings = FALSE)
      googledrive::drive_download(hit, path = local_path, overwrite = TRUE)
      if (verbose) message("  <- Drive: ", local_path)
      if (valid_local(local_path)) return(local_path)
      ## Drive hit failed validation — fall through to tier 3.
    }
  }
  
  if (!is.null(fetch_fn)) {
    dir.create(dirname(local_path), recursive = TRUE, showWarnings = FALSE)
    fetch_fn(local_path)
    if (verbose) message("  <- fetched: ", local_path)
    if (valid_local(local_path)) return(local_path)
    stop("Cannot resolve: ", local_path,
         "\n  Fetched file failed validation.")
  }
  
  stop("Cannot resolve: ", local_path,
       "\n  Not found (or invalid) locally or on Drive.",
       if (!is.null(drive_path)) paste0("\n  Drive path tried: ", drive_path),
       "\n  Run the upstream step first, or check Drive sync.")
}

push_output <- function(local_path, drive_rel_path) {
  if (!isTRUE(getOption("mih.push", default = TRUE))) return(invisible(NULL))
  verbose <- isTRUE(getOption("mih.resolve.verbose", default = TRUE))
  
  googledrive::drive_auth(email = DRIVE_AUTH)
  drive_full <- file.path(DRIVE_ROOT, drive_rel_path)
  existing   <- tryCatch(googledrive::drive_get(drive_full), error = function(e) NULL)
  if (!is.null(existing) && nrow(existing) > 0) {
    googledrive::drive_update(googledrive::as_id(existing$id[1]), media = local_path)
    if (verbose) message("  -> Drive (updated): ", drive_full)
  } else {
    googledrive::drive_upload(local_path, path = dirname(drive_full),
                              name = basename(drive_full))
    if (verbose) message("  -> Drive (new): ", drive_full)
  }
}

## ── Script-scoped scratch directory ──────────────────────────────────────────
##
## Creates an isolated working directory for the caller's unzipped files,
## intermediate TIFs, or anything else that needs a scratch location. Also
## redirects terra's internal temp files to a separate directory so terra's
## aggressive cleanup can't remove files the script is still using.
##
## Both directories are removed automatically when the R process ends —
## normal exit, error, or RStudio session close. Agents do not need to
## register cleanup themselves or call unlink() at the end of the script.
##
## Usage:
##   scratch <- mih_new_scratch()
##   unzip(some_zip, exdir = scratch)
##   # ... write outputs to scratch, read terra rasters, whatever ...
##   # No cleanup code needed. Script exit handles it.
##
## Returns the absolute path of the caller's scratch directory. The terra
## temp directory is handled internally and not surfaced.

mih_new_scratch <- function(pattern = "mih_") {
  script_scratch <- tempfile(pattern = paste0(pattern, "scratch_"))
  script_terra   <- tempfile(pattern = paste0(pattern, "terra_"))
  dir.create(script_scratch)
  dir.create(script_terra)
  
  ## Redirect terra's internal temp files to its own directory, so terra's
  ## housekeeping can't sweep files the caller wrote.
  if (requireNamespace("terra", quietly = TRUE)) {
    terra::terraOptions(tempdir = script_terra)
  }
  
  ## Track both dirs in a package-private env so mih_cleanup_scratch() can
  ## find them. finalize runs when R exits (any mode).
  if (!exists(".mih_scratch_dirs", envir = globalenv(), inherits = FALSE)) {
    assign(".mih_scratch_dirs", character(0), envir = globalenv())
    reg.finalizer(globalenv(), function(e) {
      dirs <- get(".mih_scratch_dirs", envir = e)
      for (d in dirs) {
        if (dir.exists(d)) unlink(d, recursive = TRUE, force = TRUE)
      }
    }, onexit = TRUE)
  }
  existing_dirs <- get(".mih_scratch_dirs", envir = globalenv())
  assign(".mih_scratch_dirs",
         c(existing_dirs, script_scratch, script_terra),
         envir = globalenv())
  
  script_scratch
}