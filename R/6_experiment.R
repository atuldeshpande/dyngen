# Experiment =====================================================
#' Run an experiment from a simulation
#' @param simulation The simulation
#' @param gs The gold standard
#' @param sampler Function telling how the cells should be sampled
#' @param platform Platform
#' @importFrom stats rbinom rpois
#' @export
run_experiment <- function(
  simulation, 
  gs,
  sampler,
  platform
) {
  # mutate <- dplyr::mutate
  # filter <- dplyr::filter
  
  # first sample the cells from the sample, using the given number of cells from the platform
  n_cells <- platform$n_cells
  sampled <- sampler(simulation, gs, n_cells)
  expression_simulated <- sampled$expression
  rownames(expression_simulated) <- paste0("C", seq_len(nrow(expression_simulated)))
  cell_info <- sampled$cell_info %>% mutate(cell_id = rownames(expression_simulated))
  
  n_features_simulated <- ncol(expression_simulated)
  
  # generate housekeeping expression
  # number of genes housekeeping depends on the fraction in the reference dataset
  n_features_housekeeping <- round((n_features_simulated / platform$trajectory_dependent_features) * (1 - platform$trajectory_dependent_features))
  n_features <- n_features_simulated + n_features_housekeeping
  
  # we now extract the splatter estimates
  estimate <- platform$estimate
  attr(estimate, "nGenes") <- n_features_housekeeping
  attr(estimate, "nCells") <- n_cells;attr(estimate, "groupCells") <- n_cells;attr(estimate, "batchCells") <- n_cells;
  
  class(estimate) <- "SplatParams" # trick splatter into thinking this is a splatparams class, avoiding it to load in a bunch of functions in the global environment, most of them coming from scater -__-
  
  housekeeping_simulation <- splatter::splatSimulateSingle(estimate)
  
  # we only use the earlier steps from the result of splatSimulateSingle, but then you need to dig deep into splat::: 's ...
  # we now combine the genemeans from splatter with the simulated expression values
  # then use the libsizes from splatter to estimate the "true" expression from each cell, which will then be used to estimate the true counts
  
  simulated_expression_factor <- SingleCellExperiment::rowData(housekeeping_simulation)$GeneMean %>% sort() %>% tail(min(n_features_simulated, n_features_housekeeping)) %>% mean()
  
  # see splatter:::splatSimSingleCellMeans
  exp.lib.sizes <- SingleCellExperiment::colData(housekeeping_simulation)$ExpLibSize
  cell.means.gene <- rep(SingleCellExperiment::rowData(housekeeping_simulation)$GeneMean, n_cells) %>% matrix(ncol = n_cells)
  cell.means.gene <- rbind(
    cell.means.gene, 
    t(expression_simulated / mean(expression_simulated) * simulated_expression_factor)
  )
  cell.props.gene <- t(t(cell.means.gene)/colSums(cell.means.gene))
  expression <- t(t(cell.props.gene) * exp.lib.sizes)
  feature_info <- tibble(gene_id = ifelse(rownames(expression) == "", paste0("H", seq_len(nrow(expression))), rownames(expression)), housekeeping = rownames(expression) == "")
  rownames(expression) <- feature_info$gene_id
  
  # see splatter:::splatSimTrueCounts
  true_counts <- matrix(stats::rpois(n_features * n_cells, lambda = expression), nrow = n_features, ncol = n_cells)
  dimnames(true_counts) <- dimnames(expression)
  
  # true_counts %>% {log2(. + 1)} %>% apply(1, sd) %>% sort() %>% rev() %>% head(100) %>% names()
  
  # finally, if present, dropouts will be simulated
  # see splatter:::splatSimDropout
  logistic <- function (x, x0, k) {1/(1 + exp(-k * (x - x0)))}
  if (TRUE) {
    drop.prob <- sapply(seq_len(n_cells), function(idx) {
      eta <- log(expression[, idx])
      return(logistic(eta, x0 = estimate@dropout.mid, k = estimate@dropout.shape))
    })
    keep <- matrix(stats::rbinom(n_cells * n_features, 1, 1 - drop.prob), 
                   nrow = n_features, ncol = n_cells)
    
    counts <- true_counts
    counts[!keep] <- 0
  } else {
    counts <- true_counts
  }
  dimnames(counts) <- dimnames(true_counts)
  
  experiment <- lst(
    cell_info,
    expression_simulated,
    expression = t(expression),
    true_counts = t(true_counts),
    counts = t(counts),
    feature_info
  )
}



# Sample snapshet --------------
sample_snapshot <- function(simulation, gs, ncells = 500, weight_bw = 0.1) {
  # determine weights using the density
  progressions <- gs$progressions %>% 
    group_by(edge_id) %>% 
    mutate(density = approxfun(density(percentage, bw=weight_bw))(percentage)) %>% 
    mutate(weight = 1/density) %>% 
    ungroup()
  
  sample_ids <- progressions %>% 
    filter(!burn) %>% 
    # group_by(step_id) %>% 
    # summarise() %>% 
    sample_n(ncells, weight = weight) %>% 
    pull(step_id)
  expression <- simulation$expression[sample_ids, ]
  
  lst(expression, cell_info = tibble(step_id = sample_ids))
}

#' Snapshot sampler
#' @param weight_bw The bandwidth for density estimation, measured in "percentage" units
#' @export
snapshot_sampler <- function(weight_bw = 0.1) {
  function(simulation, gs, ncells) {sample_snapshot(simulation, gs, ncells = ncells, weight_bw = weight_bw)}
}

# Sample synchronised ----------
sample_synchronised <- function(simulation, gs, ntimepoints = 10, timepoints = seq(0, max(simulation$step_info$simulationtime), length.out = ntimepoints), ncells_per_timepoint = 12) {
  ncells_per_timepoint <- min(ncells_per_timepoint, length(unique(simulation$step_info$simulation_id)))
  
  non_burn_step_ids <- gs$progressions %>% 
    filter(!burn) %>% 
    pull(step_id) %>% 
    unique()
  
  step_info <- simulation$step_info %>% filter(step_id %in% non_burn_step_ids)
  
  sample_step_info <- map_dfr(timepoints, function(timepoint) {
    step_info %>% group_by(simulation_id) %>% 
      summarise(step_id = step_id[which.min(abs(simulationtime - timepoint))]) %>% 
      mutate(timepoint = timepoint) %>% 
      sample_n(ncells_per_timepoint)
  })
  
  lst(
    expression = simulation$expression[sample_step_info$step_id, ],
    cell_info = sample_step_info
  )
}
#' Snapshot sampler
#' @param ntimepoints Number of timepoints to sample
#' @export
synchronised_sampler <- function(ntimepoints = 10) {
  function(simulation, gs) sample_synchronised(simulation, gs, ntimepoints = ntimepoints)
}

#' Checks the expression for certain properties
#' 
#' @param expression Expression matrix
#' @export
check_expression <- function(expression) {
  checks <- list(
    contains_na = any(is.na(expression)),
    contains_zero_cells = any(apply(expression, 1, max) == 0),
    contains_zero_genes = any(apply(expression, 2, max) == 0),
    contains_nonchanging_cells = any(is.na(apply(expression, 1, sd))),
    contains_nonchanging_genes = any(is.na(apply(expression, 2, sd)))
  )
  
  checks
}

#' Filter counts
#' 
#' @param experiment Experiment list, containing expression, cell_info and feature_info
#' 
#' @export
filter_experiment <- function(experiment) {
  remove_cells <- (apply(experiment$expression, 1, max) == 0) | is.na(apply(experiment$expression, 1, sd))
  
  experiment$expression <- experiment$expression[!remove_cells, ]
  experiment$cell_info <- experiment$cell_info %>% slice(match(rownames(experiment$expression), cell_id))
  experiment
}