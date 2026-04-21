## 03_enm.R -- Species distribution models: ENMeval/AICc and bootstrap x15
## MIH Pipeline Step 03
## ---------------------------------------------------------------------------
## Fits MaxEnt models along two method tracks, both run per invocation:
##
##   Track A (ENMeval/AICc): ENMeval v2 + `maxnet`, 4-fold spatial block CV
##     (get.block), tuning grid fc in {L, LQ, LQH} x rm in {0.5, 1, ..., 4.0},
##     lowest-AICc setting selected, projected once.
##
##   Track B (bootstrap x15): dismo::maxent (maxent.jar) with defaults; 15
##     presence-resampled replicates per species x extent; per-cell mean and
##     SD across replicates. Reproduces Karl's FinalResults approach.
##
## 3 species x 2 extents x 2 method tracks = 12 prediction rasters. Outputs
## are prefixed `03a_` (ENMeval) or `03b_` (bootstrap) so Step 04 can consume
## one or both tracks independently.
##
## Decision #2 (STATUS.md): run both tracks -- resolved.
##
## Inputs (all at flat outputs/ per PIPELINE_SPEC filename convention):
##   outputs/01_env_stack_{STACK}.tif         -- env stack selected via STACK
##   outputs/02_occ_{hist_aeg,mod_aeg,mod_albo}_thinned.csv
##   outputs/00_occ_raw_inat.csv              -- optional validation overlay
##
## Outputs (all at flat outputs/):
##   Track A (ENMeval):
##     03a_enm_model_summary.csv              -- fc, rm, AICc, AUC, OR10 per model
##     03a_enm_pred_{sp}_{extent}.tif         -- 6 prediction rasters
##     03a_enm_varimp_{sp}_{extent}.csv       -- 6 variable-importance tables
##     03a_enm_results_{sp}_{extent}.csv      -- 6 full tuning tables
##     03a_fig_response_{sp}_{extent}.png     -- 6 response-curve panels
##   Track B (bootstrap):
##     03b_enm_model_summary.csv              -- n_boot, AUC/gain mean/sd per model
##     03b_enm_pred_{sp}_{extent}.tif         -- 6 bootstrap-mean rasters
##     03b_enm_predsd_{sp}_{extent}.tif       -- 6 bootstrap-SD rasters
##     03b_enm_varimp_{sp}_{extent}.csv       -- 6 variable-importance tables
##     03b_enm_bootruns_{sp}_{extent}.csv     -- 6 per-bootstrap AUC/gain tables
##     03b_fig_response_{sp}_{extent}.png     -- 6 response-curve panels (rep 1)
##   Shared / combined:
##     03_background_points.csv               -- 10k bg points (reused by Step 05)
##     03_step03_summary.txt                  -- combined log
## ---------------------------------------------------------------------------

library(here)
library(conflicted)
library(googledrive)
library(terra)
library(ENMeval)
library(maxnet)
library(dismo)
library(rJava)
library(raster)        # dismo::maxent still needs RasterStack as input
library(dplyr)
library(readr)
library(ggplot2)

conflicted::conflicts_prefer(dplyr::filter, dplyr::lag, dplyr::select,
                             terra::extract, base::intersect, base::setdiff)

source(here::here("scripts/_pipeline_boilerplate.R"))
options(warn = 1)

## -- Configuration ----------------------------------------------------------
## STACK selects the env stack from Step 01. Edit here; re-run for each track
## combination to compare.

STACK <- "trackB_contemporary"   # trackA_contemporary | trackB_contemporary |
                                 # trackB_historic

RUN_ENMEVAL   <- TRUE             # Track A: ENMeval + AICc
RUN_BOOTSTRAP <- TRUE             # Track B: dismo::maxent bootstrap x15

## Variable selection per stack.
##   Track B: Karl's 6 bioclim + elevation (settled via decision #1 resolution).
##   Track A: OPEN DECISION. Placeholder uses the same 6 + elevation, which
##   ignores Climate Atlas layers -- NOT manuscript-faithful. Revisit once
##   the variable-selection sub-decision under #1 resolves.
## ⚑ FLAG [track A var selection]: Track A variable selection is an open
## decision (STATUS #1 follow-on). Current placeholder inherits Track B's
## 6-bioclim + elevation set, omitting Climate Atlas. This is wrong for the
## Track A run; correct before any Track A results enter the manuscript.
VAR_SETS <- list(
  trackB_contemporary = c(paste0("bio", c(1, 3, 4, 7, 12, 15)), "elevation"),
  trackB_historic     = c(paste0("bio", c(1, 3, 4, 7, 12, 15)), "elevation"),
  trackA_contemporary = c(paste0("bio", c(1, 3, 4, 7, 12, 15)), "elevation")
)

SPECIES <- c("hist_aeg", "mod_aeg", "mod_albo")
EXTENTS <- c("state", "BI")

## Extent bboxes. State = full stack; BI = Big Island crop.
BI_EXT <- terra::ext(-156.10, -154.75, 18.85, 20.30)

## Shared background sample size (both methods, state and BI).
N_BG <- 10000L

## -- Track A config (ENMeval) ----------------------------------------------
FC_GRID     <- c("L", "LQ", "LQH")
RM_GRID     <- seq(0.5, 4.0, by = 0.5)
PARTITIONS  <- "block"                        # 4-fold spatial
N_CORES     <- max(1L, parallel::detectCores() - 1L)

## -- Track B config (bootstrap) --------------------------------------------
N_BOOT    <- 15L
BOOT_FRAC <- 1.0                              # resample N with replacement
MAXENT_ARGS <- c(
  "responsecurves=false",
  "jackknife=false",
  "outputformat=cloglog",
  "writebackgroundpredictions=false",
  "writeplotdata=false",
  "plots=false",
  "randomseed=true"
)

set.seed(2026)

## -- Paths ------------------------------------------------------------------
## Flat outputs/ per PIPELINE_SPEC filename convention -- no per-step
## subdirectory. Every file written here carries its step prefix.

ROOT   <- here::here()
OUTDIR <- file.path(ROOT, "outputs")
dir.create(OUTDIR, recursive = TRUE, showWarnings = FALSE)

scratch <- mih_new_scratch("mih_03_")

## -- Log --------------------------------------------------------------------

t_start   <- Sys.time()
log_lines <- character()
log_msg <- function(...) {
  msg <- paste0(...)
  cat(msg, "\n")
  log_lines <<- c(log_lines, msg)
}

log_msg("=== MIH Pipeline -- Step 03: ENM (combined) ===")
log_msg("Date:          ", format(t_start))
log_msg("Stack:         ", STACK)
log_msg("Vars:          ", paste(VAR_SETS[[STACK]], collapse = ", "))
log_msg("Run ENMeval:   ", RUN_ENMEVAL)
log_msg("Run bootstrap: ", RUN_BOOTSTRAP, if (RUN_BOOTSTRAP)
        paste0(" (N_BOOT=", N_BOOT, ")") else "")
log_msg("Background:    ", N_BG)
log_msg("Cores:         ", N_CORES)
log_msg("")

if (!RUN_ENMEVAL && !RUN_BOOTSTRAP) {
  stop("Both RUN_ENMEVAL and RUN_BOOTSTRAP are FALSE -- nothing to do.")
}

## -- maxent.jar availability (only if bootstrap requested) ------------------

if (RUN_BOOTSTRAP) {
  jar <- system.file("java", "maxent.jar", package = "dismo")
  if (!file.exists(jar)) {
    stop(
      "RUN_BOOTSTRAP = TRUE but maxent.jar not found at:\n  ", jar, "\n",
      "  Download maxent.jar from https://biodiversityinformatics.amnh.org/open_source/maxent/\n",
      "  and copy to the dismo package's java/ directory. Or set\n",
      "  RUN_BOOTSTRAP <- FALSE to run Track A only."
    )
  }
  log_msg("maxent.jar:    ", jar, " (",
          round(file.size(jar) / 1024, 1), " KB)")
  log_msg("")
}

## ============================================================================
## RESOLVE INPUTS
## ============================================================================

stack_path <- resolve(
  file.path("outputs", paste0("01_env_stack_", STACK, ".tif")),
  file.path("MIH_Mosquitoes_Hawaii/outputs",
            paste0("01_env_stack_", STACK, ".tif"))
)
env <- terra::rast(stack_path)
log_msg("Stack loaded: ", terra::nlyr(env), " layers, ", terra::ncell(env),
        " cells, res ", paste(round(terra::res(env), 5), collapse = " x "))

## Subset to configured variable set, fail loudly if any missing.
need_vars <- VAR_SETS[[STACK]]
missing_vars <- setdiff(need_vars, names(env))
if (length(missing_vars) > 0) {
  stop("Stack '", STACK, "' missing variables: ",
       paste(missing_vars, collapse = ", "),
       "\n  Available: ", paste(names(env), collapse = ", "))
}
env <- env[[need_vars]]
log_msg("Vars subset: ", terra::nlyr(env), " layers retained")
log_msg("")

## Occurrences -- one file per species.
occ_paths <- setNames(
  vapply(SPECIES, function(sp) {
    resolve(
      file.path("outputs", paste0("02_occ_", sp, "_thinned.csv")),
      file.path("MIH_Mosquitoes_Hawaii/outputs",
                paste0("02_occ_", sp, "_thinned.csv"))
    )
  }, character(1)),
  SPECIES
)
occ_list <- lapply(occ_paths, readr::read_csv, show_col_types = FALSE)
for (sp in SPECIES) {
  log_msg("Occurrences ", sp, ": ", nrow(occ_list[[sp]]), " records")
}
log_msg("")

## iNat validation -- optional, read-only. Silently unavailable is OK.
## ⚑ FLAG [iNat]: Required before manuscript submission; validation overlay
## only, not used for model fitting.
inat <- tryCatch(
  {
    p <- resolve(
      "outputs/00_occ_raw_inat.csv",
      "MIH_Mosquitoes_Hawaii/outputs/00_occ_raw_inat.csv"
    )
    readr::read_csv(p, show_col_types = FALSE)
  },
  error = function(e) NULL
)
if (is.null(inat)) {
  log_msg("iNat validation: NOT AVAILABLE (flagged; required pre-submission)")
} else {
  log_msg("iNat validation: ", nrow(inat), " records loaded")
}
log_msg("")

## ============================================================================
## HELPERS
## ============================================================================

## Crop env stack to an extent identifier. 'state' = full stack.
crop_env <- function(env, extent_id) {
  if (identical(extent_id, "state")) return(env)
  if (identical(extent_id, "BI"))    return(terra::crop(env, BI_EXT))
  stop("Unknown extent: ", extent_id)
}

## Filter occurrences to cells where the env stack has data (all layers
## non-NA). Silent drop; reported in log.
filter_to_env <- function(pts, env) {
  m <- terra::extract(env, pts[, c("lon", "lat")], ID = FALSE)
  ok <- stats::complete.cases(m)
  list(pts = pts[ok, , drop = FALSE], dropped = sum(!ok))
}

## Sample background from non-NA cells of the stack.
## Terra 1.9.11 returns a matrix from spatSample when values = FALSE, even
## with as.df = TRUE -- force coercion to data.frame for downstream `$` use.
sample_bg <- function(env, n, seed) {
  set.seed(seed)
  s <- terra::spatSample(env, size = n, method = "random",
                          na.rm = TRUE, as.df = TRUE, xy = TRUE,
                          values = FALSE)
  s <- as.data.frame(s)
  ## First two columns are x, y under xy = TRUE across terra versions;
  ## index positionally to be robust to column-name drift.
  data.frame(x = s[[1]], y = s[[2]])
}

## Muffle "closing unused connection" warnings emitted by the parallel
## package's PSOCK cluster cleanup inside ENMevaluate. Known quirk --
## not a data-quality issue. Targeted muffle keeps other warnings visible.
muffle_parallel_noise <- function(expr) {
  withCallingHandlers(
    expr,
    warning = function(w) {
      if (grepl("closing unused connection", conditionMessage(w),
                fixed = TRUE)) {
        invokeRestart("muffleWarning")
      }
    }
  )
}

## gc() that muffles connection-cleanup warnings. ENMeval's PSOCK cluster
## shutdown leaks sockets; a later gc() sweeps them and emits a warning per
## socket. Targeted muffle via muffle_parallel_noise keeps other gc warnings
## visible. Use in place of gc(verbose = FALSE) throughout the script.
quiet_gc <- function() muffle_parallel_noise(gc(verbose = FALSE))

## -- Response-curve plotter for Track A (maxnet) ----------------------------

plot_responses_maxnet <- function(mod, env_sub, out_png, title) {
  vars <- names(env_sub)
  rng <- lapply(vars, function(v) {
    vals <- terra::values(env_sub[[v]])
    vals <- vals[!is.na(vals)]
    range(vals)
  })
  names(rng) <- vars

  dfs <- lapply(vars, function(v) {
    seq_v <- seq(rng[[v]][1], rng[[v]][2], length.out = 100)
    newdata <- as.data.frame(matrix(0, nrow = 100, ncol = length(vars)))
    names(newdata) <- vars
    for (v2 in vars) {
      vv <- terra::values(env_sub[[v2]])
      newdata[[v2]] <- mean(vv, na.rm = TRUE)
    }
    newdata[[v]] <- seq_v
    p <- predict(mod, newdata, type = "cloglog", clamp = TRUE)
    data.frame(var = v, x = seq_v, y = as.numeric(p))
  })
  df <- do.call(rbind, dfs)

  g <- ggplot2::ggplot(df, ggplot2::aes(x = x, y = y)) +
    ggplot2::geom_line() +
    ggplot2::facet_wrap(~ var, scales = "free_x") +
    ggplot2::labs(title = title, x = NULL, y = "cloglog suitability") +
    ggplot2::theme_bw(base_size = 9)

  ggplot2::ggsave(out_png, g, width = 8, height = 5.5, dpi = 150)
}

## -- Response-curve plotter for Track B (maxent.jar) ------------------------

plot_responses_maxent <- function(mod, env_sub, out_png, title) {
  vars <- names(env_sub)
  dfs <- lapply(vars, function(v) {
    vals <- terra::values(env_sub[[v]])
    vals <- vals[!is.na(vals)]
    if (length(vals) < 2) return(NULL)
    seq_v <- seq(min(vals), max(vals), length.out = 100)
    newdata <- as.data.frame(matrix(0, nrow = 100, ncol = length(vars)))
    names(newdata) <- vars
    for (v2 in vars) {
      vv <- terra::values(env_sub[[v2]])
      newdata[[v2]] <- mean(vv, na.rm = TRUE)
    }
    newdata[[v]] <- seq_v
    p <- dismo::predict(mod, newdata, args = "outputformat=cloglog")
    data.frame(var = v, x = seq_v, y = as.numeric(p))
  })
  df <- do.call(rbind, dfs)
  if (is.null(df) || nrow(df) == 0) return(invisible(NULL))

  g <- ggplot2::ggplot(df, ggplot2::aes(x = x, y = y)) +
    ggplot2::geom_line() +
    ggplot2::facet_wrap(~ var, scales = "free_x") +
    ggplot2::labs(title = title, x = NULL, y = "cloglog suitability") +
    ggplot2::theme_bw(base_size = 9)

  ggplot2::ggsave(out_png, g, width = 8, height = 5.5, dpi = 150)
}

## -- Single bootstrap replicate for Track B ---------------------------------
## env_raster is a pre-converted RasterStack (dismo::maxent requires it).
## Resampling happens here; seed is set by the caller so runs are reproducible.

fit_one_boot <- function(pres_xy, bg_xy, env_raster, boot_idx, run_dir) {
  n <- nrow(pres_xy)
  idx <- sample.int(n, size = ceiling(n * BOOT_FRAC), replace = TRUE)
  pres_b <- pres_xy[idx, , drop = FALSE]

  pres_sp <- as.matrix(pres_b[, c("x", "y")])
  bg_sp   <- as.matrix(bg_xy[,   c("x", "y")])

  d <- file.path(run_dir, sprintf("boot_%02d", boot_idx))
  dir.create(d, recursive = TRUE, showWarnings = FALSE)

  m <- dismo::maxent(
    x    = env_raster,
    p    = pres_sp,
    a    = bg_sp,
    args = MAXENT_ARGS,
    path = d
  )

  pr <- dismo::predict(m, env_raster, args = "outputformat=cloglog")
  pr_terra <- terra::rast(pr)

  res <- m@results
  get_row <- function(name) {
    i <- which(rownames(res) == name)
    if (length(i) == 0) return(NA_real_)
    as.numeric(res[i[1], 1])
  }
  auc  <- get_row("Training.AUC")
  gain <- get_row("Regularized.training.gain")

  vars <- names(env_raster)
  pc <- vapply(paste0(vars, ".contribution"),          get_row, numeric(1))
  pi <- vapply(paste0(vars, ".permutation.importance"), get_row, numeric(1))
  names(pc) <- vars
  names(pi) <- vars

  list(model = m, pred = pr_terra, auc = auc, gain = gain,
       pc = pc, pi = pi, n_sample = nrow(pres_b))
}

## ============================================================================
## BACKGROUND POINTS (shared across tracks and species; written once)
## ============================================================================

log_msg("Sampling statewide background (", N_BG, ") ...")
bg_state <- sample_bg(env, N_BG, seed = 2026L)
log_msg("  sampled: ", nrow(bg_state))

log_msg("Sampling BI background (", N_BG, ") ...")
env_BI_full <- crop_env(env, "BI")
bg_BI <- sample_bg(env_BI_full, N_BG, seed = 2026L + 1L)
log_msg("  sampled: ", nrow(bg_BI))

bg_path <- file.path(OUTDIR, "03_background_points.csv")
bg_both <- rbind(
  data.frame(extent = "state", bg_state),
  data.frame(extent = "BI",    bg_BI)
)
readr::write_csv(bg_both, bg_path)
push_output(bg_path, "outputs/03_background_points.csv")
log_msg("")

## ============================================================================
## MAIN LOOP -- species x extent, with both method tracks per cell
## ============================================================================

enmeval_rows   <- list()
bootstrap_rows <- list()
timings_A      <- list()
timings_B      <- list()

for (sp in SPECIES) {
  occ_sp <- occ_list[[sp]]
  if (!all(c("lon", "lat") %in% names(occ_sp))) {
    stop("Occurrence file for ", sp, " missing lon/lat columns.")
  }

  for (extent_id in EXTENTS) {
    tag <- paste0(sp, "_", extent_id)
    log_msg("======== ", tag, " ========")

    env_sub <- crop_env(env, extent_id)
    bg_sub  <- if (identical(extent_id, "state")) bg_state else bg_BI

    ## Shared presence filtering.
    if (identical(extent_id, "BI")) {
      in_BI <- occ_sp$lon >= BI_EXT[1] & occ_sp$lon <= BI_EXT[2] &
               occ_sp$lat >= BI_EXT[3] & occ_sp$lat <= BI_EXT[4]
      occ_x <- occ_sp[in_BI, , drop = FALSE]
    } else {
      occ_x <- occ_sp
    }
    filt <- filter_to_env(occ_x, env_sub)
    occ_x <- filt$pts
    if (filt$dropped > 0) {
      log_msg("  ", filt$dropped, " presences dropped (NA env after Step 02)")
    }
    n_pres <- nrow(occ_x)
    log_msg("  presences: ", n_pres, " | background: ", nrow(bg_sub))

    if (n_pres < 10) {
      log_msg("  SKIP: fewer than 10 presences after filtering.")
      if (RUN_ENMEVAL) {
        enmeval_rows[[tag]] <- data.frame(
          species = sp, extent = extent_id, method = "ENMeval",
          n_presence = n_pres, n_background = nrow(bg_sub),
          fc = NA, rm = NA, AICc = NA,
          delta_AICc_tunings = NA,
          AUC_val_avg = NA, AUC_val_sd = NA, OR10_val_avg = NA,
          status = "skipped_low_n", stringsAsFactors = FALSE
        )
      }
      if (RUN_BOOTSTRAP) {
        bootstrap_rows[[tag]] <- data.frame(
          species = sp, extent = extent_id, method = "bootstrap",
          n_presence = n_pres, n_background = nrow(bg_sub),
          n_boot = 0, AUC_mean = NA, AUC_sd = NA,
          gain_mean = NA, gain_sd = NA,
          status = "skipped_low_n", stringsAsFactors = FALSE
        )
      }
      log_msg("")
      next
    }

    occ_xy <- data.frame(x = occ_x$lon, y = occ_x$lat)
    bg_xy  <- data.frame(x = bg_sub$x,  y = bg_sub$y)

    ## ----------------------------------------------------------------------
    ## TRACK A -- ENMeval / AICc
    ## ----------------------------------------------------------------------
    if (RUN_ENMEVAL) {
      log_msg("  -- Track A (ENMeval) --")
      t0 <- Sys.time()

      e <- tryCatch(
        muffle_parallel_noise(
          ENMeval::ENMevaluate(
            occs           = occ_xy,
            envs           = env_sub,
            bg             = bg_xy,
            algorithm      = "maxnet",
            partitions     = PARTITIONS,
            tune.args      = list(fc = FC_GRID, rm = RM_GRID),
            parallel       = TRUE,
            numCores       = N_CORES,
            updateProgress = FALSE,  # shiny progress bar; not useful here
            quiet          = FALSE   # keep tuning-grid progress visible
          )
        ),
        error = function(err) {
          log_msg("    ENMevaluate error: ", conditionMessage(err))
          NULL
        }
      )

      if (is.null(e)) {
        enmeval_rows[[tag]] <- data.frame(
          species = sp, extent = extent_id, method = "ENMeval",
          n_presence = n_pres, n_background = nrow(bg_sub),
          fc = NA, rm = NA, AICc = NA,
          delta_AICc_tunings = NA,
          AUC_val_avg = NA, AUC_val_sd = NA, OR10_val_avg = NA,
          status = "enmevaluate_failed", stringsAsFactors = FALSE
        )
      } else {
        res <- e@results
        res$delta.AICc[is.na(res$delta.AICc)] <- Inf
        best <- res[which.min(res$delta.AICc), ]
        best_idx <- which(res$tune.args == best$tune.args)[1]
        best_mod <- e@models[[best_idx]]

        log_msg("    best: fc=", best$fc, " rm=", best$rm,
                " | AICc=", round(best$AICc, 2),
                " dAICc=", round(best$delta.AICc, 2),
                " AUC=", round(best$auc.val.avg, 3),
                " OR10=", round(best$or.10p.avg, 3))

        pred <- ENMeval::maxnet.predictRaster(
          mod = best_mod, envs = env_sub,
          pred.type = "cloglog", doClamp = TRUE
        )
        pred_path <- file.path(OUTDIR, paste0("03a_enm_pred_", tag, ".tif"))
        terra::writeRaster(pred, pred_path, overwrite = TRUE,
                            datatype = "FLT4S", gdal = "COMPRESS=LZW")
        push_output(pred_path, file.path("outputs", basename(pred_path)))

        res_path <- file.path(OUTDIR, paste0("03a_enm_results_", tag, ".csv"))
        readr::write_csv(res, res_path)
        push_output(res_path, file.path("outputs", basename(res_path)))

        ## ⚑ FLAG [maxnet varimp]: maxnet does not compute MaxEnt's
        ## permutation importance. This varimp is sum(|standardised
        ## coefficient|) per variable across feature terms. Comparable
        ## within Track A runs; not directly comparable to maxent.jar
        ## permutation importance. Track B output is comparable to Karl's.
        coefs <- best_mod$betas
        varimp <- data.frame(
          variable   = need_vars,
          importance = vapply(need_vars, function(v) {
            term_idx <- grepl(
              paste0("(^|[^a-zA-Z_])", v, "($|[^a-zA-Z_0-9])"),
              names(coefs))
            sum(abs(coefs[term_idx]))
          }, numeric(1)),
          stringsAsFactors = FALSE
        )
        varimp$importance_pct <- 100 * varimp$importance /
          max(sum(varimp$importance), .Machine$double.eps)
        varimp <- varimp[order(-varimp$importance_pct), ]
        varimp_path <- file.path(OUTDIR, paste0("03a_enm_varimp_", tag, ".csv"))
        readr::write_csv(varimp, varimp_path)
        push_output(varimp_path,
                    file.path("outputs", basename(varimp_path)))

        resp_path <- file.path(OUTDIR, paste0("03a_fig_response_", tag, ".png"))
        plot_responses_maxnet(
          best_mod, env_sub, resp_path,
          title = paste0(sp, " -- ", extent_id,
                         " [Track A: fc=", best$fc, " rm=", best$rm, "]"))
        push_output(resp_path,
                    file.path("outputs", basename(resp_path)))

        enmeval_rows[[tag]] <- data.frame(
          species            = sp,
          extent             = extent_id,
          method             = "ENMeval",
          n_presence         = n_pres,
          n_background       = nrow(bg_sub),
          fc                 = as.character(best$fc),
          rm                 = as.numeric(as.character(best$rm)),
          AICc               = best$AICc,
          delta_AICc_tunings = best$delta.AICc,
          AUC_val_avg        = best$auc.val.avg,
          AUC_val_sd         = best$auc.val.sd,
          OR10_val_avg       = best$or.10p.avg,
          status             = "ok",
          stringsAsFactors   = FALSE
        )

        rm(e, best_mod, pred); quiet_gc()
      }

      timings_A[[tag]] <- as.numeric(round(difftime(Sys.time(), t0,
                                                   units = "mins"), 1))
      log_msg("    time: ", timings_A[[tag]], " min")
    }

    ## ----------------------------------------------------------------------
    ## TRACK B -- bootstrap x N_BOOT
    ## ----------------------------------------------------------------------
    if (RUN_BOOTSTRAP) {
      log_msg("  -- Track B (bootstrap x", N_BOOT, ") --")
      t0 <- Sys.time()

      ## dismo::maxent needs RasterStack, not terra SpatRaster. Convert
      ## once per extent (not per-replicate) and pass into the helper.
      env_raster <- raster::stack(env_sub)

      run_dir <- file.path(scratch, tag)
      dir.create(run_dir, recursive = TRUE, showWarnings = FALSE)

      boot_out <- vector("list", N_BOOT)
      for (b in seq_len(N_BOOT)) {
        set.seed(2026L + 100L * match(sp, SPECIES) +
                     10L * match(extent_id, EXTENTS) + b)
        boot_out[[b]] <- tryCatch(
          fit_one_boot(occ_xy, bg_xy, env_raster, b, run_dir),
          error = function(err) {
            log_msg("    boot ", b, " failed: ", conditionMessage(err))
            NULL
          }
        )
      }
      ok <- !vapply(boot_out, is.null, logical(1))
      n_ok <- sum(ok)
      log_msg("    replicates completed: ", n_ok, " / ", N_BOOT)

      if (n_ok == 0) {
        bootstrap_rows[[tag]] <- data.frame(
          species = sp, extent = extent_id, method = "bootstrap",
          n_presence = n_pres, n_background = nrow(bg_sub),
          n_boot = 0, AUC_mean = NA, AUC_sd = NA,
          gain_mean = NA, gain_sd = NA,
          status = "all_boots_failed", stringsAsFactors = FALSE
        )
      } else {
        boot_ok <- boot_out[ok]

        pred_stack <- terra::rast(lapply(boot_ok, `[[`, "pred"))
        pred_mean <- terra::app(pred_stack, mean, na.rm = TRUE)
        pred_sd   <- terra::app(pred_stack, stats::sd, na.rm = TRUE)
        names(pred_mean) <- "cloglog_mean"
        names(pred_sd)   <- "cloglog_sd"

        pred_path <- file.path(OUTDIR, paste0("03b_enm_pred_",   tag, ".tif"))
        sd_path   <- file.path(OUTDIR, paste0("03b_enm_predsd_", tag, ".tif"))
        terra::writeRaster(pred_mean, pred_path, overwrite = TRUE,
                            datatype = "FLT4S", gdal = "COMPRESS=LZW")
        terra::writeRaster(pred_sd,   sd_path,   overwrite = TRUE,
                            datatype = "FLT4S", gdal = "COMPRESS=LZW")
        push_output(pred_path, file.path("outputs", basename(pred_path)))
        push_output(sd_path,   file.path("outputs", basename(sd_path)))

        runs <- data.frame(
          boot     = seq_along(boot_ok),
          n_sample = vapply(boot_ok, `[[`, numeric(1), "n_sample"),
          AUC      = vapply(boot_ok, `[[`, numeric(1), "auc"),
          gain     = vapply(boot_ok, `[[`, numeric(1), "gain"),
          stringsAsFactors = FALSE
        )
        runs_path <- file.path(OUTDIR, paste0("03b_enm_bootruns_", tag, ".csv"))
        readr::write_csv(runs, runs_path)
        push_output(runs_path, file.path("outputs", basename(runs_path)))

        pc_mat <- do.call(rbind, lapply(boot_ok, `[[`, "pc"))
        pi_mat <- do.call(rbind, lapply(boot_ok, `[[`, "pi"))
        varimp <- data.frame(
          variable                    = need_vars,
          percent_contribution_mean   = colMeans(pc_mat, na.rm = TRUE),
          percent_contribution_sd     = apply(pc_mat, 2, stats::sd, na.rm = TRUE),
          permutation_importance_mean = colMeans(pi_mat, na.rm = TRUE),
          permutation_importance_sd   = apply(pi_mat, 2, stats::sd, na.rm = TRUE),
          stringsAsFactors = FALSE
        )
        varimp <- varimp[order(-varimp$percent_contribution_mean), ]
        varimp_path <- file.path(OUTDIR, paste0("03b_enm_varimp_", tag, ".csv"))
        readr::write_csv(varimp, varimp_path)
        push_output(varimp_path,
                    file.path("outputs", basename(varimp_path)))

        resp_path <- file.path(OUTDIR, paste0("03b_fig_response_", tag, ".png"))
        plot_responses_maxent(
          boot_ok[[1]]$model, env_sub, resp_path,
          title = paste0(sp, " -- ", extent_id,
                         " [Track B: rep 1 of ", n_ok, "]"))
        if (file.exists(resp_path)) {
          push_output(resp_path,
                      file.path("outputs", basename(resp_path)))
        }

        bootstrap_rows[[tag]] <- data.frame(
          species      = sp,
          extent       = extent_id,
          method       = "bootstrap",
          n_presence   = n_pres,
          n_background = nrow(bg_sub),
          n_boot       = n_ok,
          AUC_mean     = mean(runs$AUC, na.rm = TRUE),
          AUC_sd       = stats::sd(runs$AUC, na.rm = TRUE),
          gain_mean    = mean(runs$gain, na.rm = TRUE),
          gain_sd      = stats::sd(runs$gain, na.rm = TRUE),
          status       = "ok",
          stringsAsFactors = FALSE
        )

        log_msg("    AUC:  ", round(bootstrap_rows[[tag]]$AUC_mean, 3),
                " +/- ", round(bootstrap_rows[[tag]]$AUC_sd, 3))
        log_msg("    gain: ", round(bootstrap_rows[[tag]]$gain_mean, 3),
                " +/- ", round(bootstrap_rows[[tag]]$gain_sd, 3))

        rm(boot_ok, pred_stack, pred_mean, pred_sd); quiet_gc()
      }
      rm(boot_out, env_raster); quiet_gc()

      timings_B[[tag]] <- as.numeric(round(difftime(Sys.time(), t0,
                                                   units = "mins"), 1))
      log_msg("    time: ", timings_B[[tag]], " min")
    }

    log_msg("")
  }
}

## ============================================================================
## WRITE SUMMARIES + COMBINED LOG
## ============================================================================

if (RUN_ENMEVAL) {
  summary_A <- do.call(rbind, enmeval_rows)
  path_A <- file.path(OUTDIR, "03a_enm_model_summary.csv")
  readr::write_csv(summary_A, path_A)
  push_output(path_A, "outputs/03a_enm_model_summary.csv")
}

if (RUN_BOOTSTRAP) {
  summary_B <- do.call(rbind, bootstrap_rows)
  path_B <- file.path(OUTDIR, "03b_enm_model_summary.csv")
  readr::write_csv(summary_B, path_B)
  push_output(path_B, "outputs/03b_enm_model_summary.csv")
}

t_total <- as.numeric(round(difftime(Sys.time(), t_start, units = "mins"), 1))

log_msg("=== Step 03 complete ===")
log_msg("Total time: ", t_total, " min")
log_msg("")

if (RUN_ENMEVAL) {
  log_msg("Track A (ENMeval) timings:")
  for (nm in names(timings_A)) {
    log_msg("  ", nm, ": ", timings_A[[nm]], " min")
  }
  log_msg("")
  log_msg("Track A summary:")
  for (i in seq_len(nrow(summary_A))) {
    r <- summary_A[i, ]
    log_msg(sprintf("  %-20s fc=%-3s rm=%3.1f  AICc=%8.2f  AUC=%.3f  [%s]",
                    paste(r$species, r$extent, sep = "_"),
                    ifelse(is.na(r$fc), "-", r$fc),
                    ifelse(is.na(r$rm), 0, r$rm),
                    ifelse(is.na(r$AICc), NA_real_, r$AICc),
                    ifelse(is.na(r$AUC_val_avg), NA_real_, r$AUC_val_avg),
                    r$status))
  }
  log_msg("")
}

if (RUN_BOOTSTRAP) {
  log_msg("Track B (bootstrap) timings:")
  for (nm in names(timings_B)) {
    log_msg("  ", nm, ": ", timings_B[[nm]], " min")
  }
  log_msg("")
  log_msg("Track B summary:")
  for (i in seq_len(nrow(summary_B))) {
    r <- summary_B[i, ]
    log_msg(sprintf("  %-20s n_boot=%2d  AUC=%.3f +/- %.3f  gain=%.3f  [%s]",
                    paste(r$species, r$extent, sep = "_"),
                    r$n_boot,
                    ifelse(is.na(r$AUC_mean), NA_real_, r$AUC_mean),
                    ifelse(is.na(r$AUC_sd),   NA_real_, r$AUC_sd),
                    ifelse(is.na(r$gain_mean), NA_real_, r$gain_mean),
                    r$status))
  }
  log_msg("")
}

log_path <- file.path(OUTDIR, "03_step03_summary.txt")
writeLines(log_lines, log_path)
push_output(log_path, "outputs/03_step03_summary.txt")

cat("\nLog written to:", log_path, "\n")
cat("Step 03 done.\n")
