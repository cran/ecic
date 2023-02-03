##' @title Estimate a changes-in-changes model with multiple periods and cohorts
##' 
##' @description Calculates a changes-in-changes model as in Athey and Imbens (2006) for multiple periods and cohorts.
##' 
##' @param yvar Dependent variable.
##' @param gvar Group variable. Can be either a string (e.g., "first_treated") 
##' or an expression (e.g., first_treated). In a staggered treatment setting, 
##' the group variable typically denotes treatment cohort.
##' @param tvar Time variable. Can be a string (e.g., "year") or an expression
##' (e.g., year).
##' @param ivar Index variable. Can be a string (e.g., "country") or an 
##' expression (e.g., country). Only needed to check cohort sizes.
##' @param dat The data set.
##' @param myProbs Quantiles that the quantile treatment effects should be calculated for.
##' @param nMin Minimum observations per groups. Small groups are deleted.
##' @param boot Bootstrap. Resampling is done over the entire data set ("normal"), 
##' but might be weighted by period-cohort size ("weighted"). 
##' @param nReps Number of bootstrap replications.
##' @param weight_n0 Weight for the aggregation of the CDFs in the control group. 
##'  `n1` uses cohort sizes (Alternative: `n0`).
##' @param weight_n1 Weight for the aggregation of the CDFs in the treatment group. 
##' `n1` uses cohort sizes (Alternative: `n0`).
##' @param quant_algo Quantile algorithm (see Wikipedia for definitions).
##' @param es Event Study (Logical). If TRUE, a quantile treatment effect is estimated for each period.
##' @param n_digits Rounding the dependent variable before aggregating the empirical CDFs 
##' reduces the size of the imputation grid. This can significantly reduce the amount 
##' of RAM used in large data sets.
##' @param periods_es Periods of the event study.
##' @param short_output Only reports essential results.
##' @param save_to_temp Logical. If TRUE, results are temporarily saved, reduces the
##' RAM needed.
##' @param print_details Logical. If TRUE, settings are printed as a check at the beginning.
##' @param nCores Number of cores used.
##' @return An `ecic` object.
##' @references 
##' Athey, Susan and Guido W. Imbens (2006). \cite{Identification and Inference in 
##' Nonlinear Difference-in-Differences Models}. 
##' \doi{10.1111/j.1468-0262.2006.00668.x}
##' @examples 
##' # Example 1. Using the small mpdta data in the did package
##' data(dat, package = "ecic")
##' dat = dat[dat$first.treat <= 1983 & dat$countyreal <= 1000,] # small data for fast running time
##' 
##' mod_res = 
##'   summary(
##'   ecic(
##'     yvar  = lemp,         # dependent variable
##'     gvar  = first.treat,  # group indicator
##'     tvar  = year,         # time indicator
##'     ivar  = countyreal,   # unit ID
##'     dat   = dat,        # dataset
##'     boot  = "normal",     # bootstrap proceduce ("no", "normal", or "weighted")
##'     nReps = 3             # number of bootstrap runs
##'     )
##'     )
##' 
##' # Basic Plot
##' ecic_plot(mod_res)
##' 
##' \donttest{
##' # Example 2. Load some larger sample data
##' data(dat, package = "ecic")
##' 
##' # Estimate a basic model with the package's sample data
##' mod_res =
##'   summary(
##'   ecic(
##'     yvar  = lemp,         # dependent variable
##'     gvar  = first.treat,  # group indicator
##'     tvar  = year,         # time indicator
##'     ivar  = countyreal,   # unit ID
##'     dat   = dat,          # dataset
##'     boot  = "weighted",   # bootstrap proceduce ("no", "normal", or "weighted")
##'     nReps = 20            # number of bootstrap runs
##'   )
##'   )
##'   
##' # Basic Plot
##' ecic_plot(mod_res)
##' 
##' # Example 3. An Event-Study Example
##' mod_res =
##'   summary(
##'   ecic(
##'     es    = TRUE,         # aggregate for every event period
##'     yvar  = lemp,         # dependent variable
##'     gvar  = first.treat,  # group indicator
##'     tvar  = year,         # time indicator
##'     ivar  = countyreal,   # unit ID
##'     dat   = dat,          # dataset
##'     boot  = "weighted",   # bootstrap proceduce ("no", "normal", or "weighted")
##'     nReps = 20            # number of bootstrap runs
##'   )
##'   )
##'   
##' # Plots
##' ecic_plot(mod_res) # aggregated in one plot
##' ecic_plot(mod_res, es_type = "for_quantiles") # individually for every quantile
##' ecic_plot(mod_res, es_type = "for_periods") # individually for every period
##' }
##' @importFrom stats aggregate quantile sd
##' @import future
##' @import furrr
##' @export
ecic = function(
                yvar = NULL, 
                gvar = NULL, 
                tvar = NULL, 
                ivar = NULL, 
                dat  = NULL, 
                myProbs = seq(.1, .9, .1),
                nMin  = 40, 
                boot  = c("no", "normal", "weighted"),
                nReps = 1,
                weight_n0 = c("n1", "n0"),
                weight_n1 = c("n1", "n0"),
                quant_algo = 1, 
                es = FALSE, 
                n_digits = NULL,
                periods_es = 6, 
                short_output = TRUE, 
                save_to_temp = FALSE, 
                print_details = FALSE,
                nCores = 1
)
{
  #-----------------------------------------------------------------------------
  # Setup
  boot      = match.arg(boot)
  weight_n0 = match.arg(weight_n0)
  weight_n1 = match.arg(weight_n1)
  treat     = NULL
  
  if (is.null(dat)) stop("A non-NULL `dat` argument is required.")
  
  # Clean Inputs
  nl = as.list(seq_along(dat))
  names(nl) = names(dat)
  yvar = eval(substitute(yvar), nl, parent.frame())
  if (is.numeric(yvar)) yvar = names(dat)[yvar]
  tvar = eval(substitute(tvar), nl, parent.frame())
  if (is.numeric(tvar)) tvar = names(dat)[tvar]
  gvar = eval(substitute(gvar), nl, parent.frame())
  if (is.numeric(gvar)) gvar = names(dat)[gvar]
  ivar = eval(substitute(ivar), nl, parent.frame())
  if (is.numeric(ivar)) ivar = names(dat)[ivar]
  
  # Check inputs
  if (is.null(gvar))   stop("A non-NULL `gvar` argument is required.")
  if (is.null(tvar))   stop("A non-NULL `tvar` argument is required.")
  if (is.null(ivar))   stop("A non-NULL `ivar` argument is required.")
  if (is.null(yvar))   stop("A non-NULL `yvar` argument is required.")
  if (!is.logical(es)) stop("`es` must be logical.")
  if (!is.logical(short_output)) stop("`short_output` must be logical.")
  if (!is.logical(save_to_temp)) stop("`save_to_temp` must be logical.")
  if (!quant_algo %in% 1:9)      stop("Invalid quantile algorithm.")
  
  # Check bootstrap
  if (boot == "no") boot = NULL
  nReps = as.integer(nReps)
  if (! nReps > 0) stop("nReps must be a positive integer.")
  if (is.null(boot) & nReps != 1){
    warning("nReps > 1 but bootstrap is deactivated. nReps is set to 1.")
    nReps = 1
  }
  
  if (save_to_temp == TRUE) temp_dir = tempdir()
  
  #-----------------------------------------------------------------------------
  # setup tvar and gvar
  dat = subset(dat, get(gvar) %in% unique(dat[[tvar]])) # exclude never-treated units

  first_period = min(dat[[tvar]], na.rm = TRUE)
  last_cohort  = max(dat[[gvar]], na.rm = TRUE) - first_period

  dat[[tvar]]  = dat[[tvar]]-(first_period-1) # start tvar at 1
  dat[[gvar]]  = dat[[gvar]]-(first_period-1) # start gvar at 1
  
  list_periods = sort(unique(dat[[tvar]])) # list of all periods
  list_cohorts = sort(unique(dat[[gvar]])) # list of all cohorts
  
  qte_cohort   = list_cohorts[-length(list_cohorts)] # omit last g (no comparison group)
  qte_cohort   = qte_cohort[qte_cohort != 1] # omit first g (no pre-period)
  if(length(qte_cohort) == 0) stop("Not enough cohorts / groups in the data set!")
  
  # max event time QTEs can be calculated for
  periods_es = length(
    list_periods[which(list_periods == qte_cohort[1]):(length(list_periods)-1)]
    ) - 1
  
  # Print settings
  if (print_details == TRUE & is.null(boot)) {
    message(paste0("Started a changes-in-changes model for ", length(unique(dat[[gvar]])) - 1, " groups and ", nrow(dat), " observations. No standard errors computed."))
  } else if (print_details == TRUE & !is.null(boot)) {
    message(paste0("Started a changes-in-changes model for ", length(unique(dat[[gvar]])) - 1, " groups and ", nrow(dat), " observations with ", nReps, " (", boot, ") bootstrap replications."))
  }
  
  # calculate group sizes
  group_sizes = stats::aggregate(stats::as.formula(paste(". ~ ", gvar)), data = dat[!duplicated(dat[, ivar]), ], FUN = length)[c(gvar, yvar)]
  names(group_sizes)[names(group_sizes) == yvar] = "N"
  
  # check number of too small groups
  diffGroup = sum(group_sizes$N <= nMin)
  if (diffGroup != 0) warning(paste0("You have ", diffGroup, " (", round(100 * diffGroup / nrow(group_sizes)), "%) too small groups (less than ", nMin, " observations). They will be dropped."))
  if (diffGroup == nrow(group_sizes)) stop("All treated cohorts are too small (you can adjust `nMin` with caution).")
  
  ################################################################################
  # Calculate all 2-by-2 CIC combinations
  
  if (.Platform$OS.type == "windows"){
    future::plan(future::multisession, workers = nCores, gc = TRUE)
  } else {
    future::plan(future::multicore, workers = nCores, gc = TRUE) 
  }
  
  # Calculate bootstrap for all possible 2x2 combinations
  res = furrr::future_map(1:nReps, function(j) {

    n1 = n0 = vector()
    y1 = y0 = name_runs = vector("list")

    # resampling for bootstrapping
      if (!is.null(boot)) {
        if (boot == "weighted") {
          cell_sizes = stats::aggregate(stats::as.formula(paste(". ~ ", gvar, "+", tvar)), data = dat, FUN = length)[c(gvar, tvar, yvar)] # count cohort-period combinations
          names(cell_sizes)[names(cell_sizes) == yvar] = "N"
          dat = merge(dat, cell_sizes, all.x = TRUE)
          data_boot = dat[sample(1:nrow(dat), size = nrow(dat), replace = TRUE, prob = dat$N), ]
          
        } else if (boot == "normal") {
          data_boot = dat[sample(1:nrow(dat), size = nrow(dat), replace = TRUE), ]
        }
      } else {
        data_boot = dat
      }
    
    # 1) treated cohorts ----
    i = 1 # start the counter for the inner loop

    for (qteCohort in qte_cohort) {

      # 2) comparison groups ----
      pre_cohort = list_cohorts[(which(list_cohorts == qteCohort)+1):list_cohorts[length(list_cohorts)]]
      
      for (preCohort in pre_cohort) {
      
        # 3) post-treatment periods ----
        qte_year = list_periods[which(list_periods == qteCohort):(which(list_periods == last_cohort))]
        qte_year = qte_year[qte_year < preCohort] # control has to be untreated
        
        # for event study: only calculate periods you're interested in
        if (es == TRUE) qte_year = qte_year[qte_year - qteCohort <= periods_es]
        
        for (qteYear in qte_year) {
          
          # 4) pre-treatment comparison periods ----
          pre_year = list_periods[list_periods < qteCohort] # both have to  be untreated in this period
          
          for (preYear in pre_year) {
            
            # prepare the data for this loop
            data_loop = subset(data_boot, get(gvar) %in% c(qteCohort, preCohort) & get(tvar) %in% c(qteYear, preYear))
            data_loop$treat = ifelse(data_loop[[gvar]] == qteCohort, 1, 0) # add a treatment dummy
            
            # catch empty groups
            nrow_treat = nrow(subset(data_loop, treat == 1))
            nrow_control = nrow(subset(data_loop, treat == 0))
            
            if (nrow_treat < nMin){
              warning(paste0("Skipped a period-cohort group in bootstrap run ", j, " (too small treatment group)"))
              next
            }
            if (nrow_control < nMin){
              warning(paste0("Skipped a period-cohort group in bootstrap run ", j, " (too small treatment group)"))
              next
            }            
            
            #-------------------------------------------------------------------
            # save the combinations (cohort / year) of this run
            name_runs[[i]] = data.frame(i, qteCohort, preCohort, qteYear, preYear)
            
            # save the group sizes for the weighting
            n1[i] = nrow_treat
            n0[i] = nrow_control
            
            #-------------------------------------------------------------------
            # Y(1)
            y1[[i]] = stats::ecdf(subset(data_loop, treat == 1 & get(tvar) == qteYear)[[yvar]])
            
            # Y(0): Construct the counterfactual
            y0[[i]] = stats::ecdf(
              stats::quantile(subset(data_loop, treat == 0 & get(tvar) == qteYear)[[yvar]],
                     probs = stats::ecdf(subset(data_loop, treat == 0 & get(tvar) == preYear)[[yvar]]) (
                       subset(data_loop, treat == 1 & get(tvar) == preYear)[[yvar]]
                     ), type = quant_algo
                     )
              )
            
            #-------------------------------------------------------------------
            i = i + 1 # update counter
          }
        }
      }
    }
    ############################################################################
    # Aggregate Results for 1 bootstrap run
    
    # collapse
    name_runs = cbind(do.call(rbind, name_runs), n1, n0) # specifications of the runs

    # prepare imputation values
    if (!is.null(n_digits)) {
      values_to_impute = sort(unique( round( dat[[yvar]], digits = n_digits)) )
    } else {
      values_to_impute = sort(unique( dat[[yvar]] ))
    }  
    
    #-----------------------------------------------------------------------------
    # impute Y(0)
    y0_imp = lapply(y0, function(ecdf_temp) {
      ecdf_temp(values_to_impute)
    })
    
    # bind rows into a matrix
    y0_imp = as.matrix(do.call(rbind, y0_imp))
    
    # aggregate all 2x2-Y(0) (weighted by cohort size)
    test0 = data.frame(values_to_impute, value = colSums(y0_imp * (n1/sum(n1))) )
    rm(y0_imp)

    # get the quantiles of interest
    y0_quant = do.call(rbind, lapply(myProbs, function(r) {
      test0$diff = test0$value - r
      test0 = subset(test0, diff >= 0)
      test0[which.min(test0$diff),]
    }))
    y0_quant = y0_quant[, !(colnames(y0_quant) == "diff")]
    
    rm(test0)
    gc()
    
    #---------------------------------------------------------------------------
    if (es == FALSE) { # average QTE
      
      # impute Y(1)
      y1_imp = lapply(y1, function(ecdf_temp) {
        ecdf_temp(values_to_impute)
      })
      
      # bind rows into a matrix
      y1_imp = as.matrix(do.call(rbind, y1_imp))
      
      # aggregate all 2x2-Y(0) (weighted by cohort size)
      test1 = data.frame(values_to_impute, value = colSums(y1_imp * (n1/sum(n1))) )
      rm(y1_imp)

      # get the quantiles of interest
      y1_quant = do.call(rbind, lapply(myProbs, function(r) {
        test1$diff = test1$value - r
        test1 = subset(test1, diff >= 0)
        test1[which.min(test1$diff),]
      }))
      y1_quant = y1_quant[, !(colnames(y1_quant) == "diff")]

      rm(test1)
      gc()
      
      # compute the QTE
      myQuant = data.frame(
        perc = myProbs,
        values = y1_quant$values_to_impute - y0_quant$values_to_impute # from CDFs
      )
      
      #-------------------------------------------------------------------------
    } else { # "event study"
      
      # impute Y(1)
      y1_imp = lapply(y1, function(ecdf_temp) {
        ecdf_temp(values_to_impute)
      })

      # check event study settings
      name_runs$diff = name_runs$qteYear - name_runs$qteCohort
      max_es = max(name_runs[["diff"]])

      if (periods_es > max_es) {
        periods_es = max_es
        warning(paste0("Bootstrap run ", j, ": Only ", periods_es, " post-treatment periods can be calculated (plus contemporaneous)."))
      }

      myQuant = lapply(0:periods_es, function(e) { # time-after-treat

        weights_temp = n1[subset(name_runs, diff == e)[["i"]]] # weights for this event time

        y1_agg = colSums(
          as.matrix(do.call(rbind, y1_imp[subset(name_runs, diff == e)[["i"]]]
          )) * (weights_temp / sum(weights_temp)) )

        test1 = data.frame(values_to_impute, value = y1_agg)
        rm(y1_agg)

        y1_quant = do.call(rbind, lapply(myProbs, function(r) {
          test1$diff = test1$value - r
          test1 = subset(test1, diff >= 0)
          test1 = test1[which.min(test1$diff), ]
        }))
        y1_quant = y1_quant[, !(colnames(y1_quant) == "diff")]

        # compute the QTE
        quant_temp = data.frame(
          perc = myProbs,
          values = y1_quant$values_to_impute - y0_quant$values_to_impute # from CDFs
        )
        return(quant_temp)
      })

      rm(y1_imp)
      gc()
    }
    
    #---------------------------------------------------------------------------
    # save to disk (saver, but maybe slower)
    if (save_to_temp == TRUE) {
      tmp_quant = tempfile(paste0(pattern = "myQuant", j, "_"), fileext = ".rds", tmpdir = temp_dir)
      tmp_name  = tempfile(paste0(pattern = "name_runs", j, "_"), fileext = ".rds", tmpdir = temp_dir)
      
      saveRDS(dat, file = tmp_quant)
      saveRDS(name_runs, file = tmp_name)
      return(j)
    }

    # just work in the RAM (output lost if crash and RAM may be too small)
    if (short_output == TRUE & save_to_temp == FALSE) {
      return(list(coefs = myQuant, name_runs = name_runs))
    } 
    if ((short_output == FALSE & save_to_temp == FALSE)) {
      return(list(coefs = myQuant, n1 = n1, n0 = n0, name_runs = name_runs, y1 = y1, y0 = y0))
    }
  },
  .options = furrr::furrr_options(seed = 123), .progress = TRUE
  )

  ##############################################################################
  # post-loop: combine the outputs files 
  if(save_to_temp == TRUE){
    res = lapply(1:nReps, function(j){
      list(
        coefs     =   lapply(list.files( path = temp_dir, pattern = paste0("myQuant", j, ""), full.names = TRUE ), readRDS)[[1]],
        name_runs =   lapply(list.files( path = temp_dir, pattern = paste0("name_runs", j, ""), full.names = TRUE ), readRDS)[[1]]
      )})
  }

  # post-loop: Overload class and new attributes (for post-estimation) ----
  if(es == TRUE) {
    periods_es = max(lengths(lapply(res, "[[", 1))-1) # substact contemporary
  } else {
    periods_es = NA
  }
  
  class(res) = c("ecic", class(res))
  attr(res, "ecic") = list(
    myProbs    = myProbs,
    es         = es,
    periods_es = periods_es
  )
  
  return(res)
}