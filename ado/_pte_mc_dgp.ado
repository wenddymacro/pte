*! version 1.1.0  24jun2026
*! v1.1.0: Add rhomat1() for independent DGP support
*! DGP data generation for Monte Carlo simulation
*! Part of pte package (Chen, Liao & Schurter, 2026)
*!
*! Generates simulated panel data with known treatment effects for MC validation.
*! Reference: DOs/mc_simulation_estimation_experiment.do L56-92

version 14.0
// =========================================================================
// _pte_mc_dgp: Generate DGP data for Monte Carlo simulation
// =========================================================================
// TASK-001.6~10:  Panel structure generation
// TASK-001.11~18: Productivity evolution (omega0, omega1)
// TASK-001.19~22: Input/output generation (lnk, lnl, lnm, lny)
// TASK-001.23~26: True ATT calculation
// =========================================================================

program define _pte_mc_dgp, rclass
    version 14.0
    
    // -----------------------------------------------------------------
    // Syntax parsing
    // -----------------------------------------------------------------
    syntax, BETAmat(string) RHOmat(string) OMEGAmat(string) ///
        Seed(integer) ///
        [TAU(real 0.06) Sigma_eps0(real 0.2) Sigma_eps1(real 0.1) ///
         Mu_v(real 0.05) Sigma_v(real 0.1) ///
         Order(integer 1) PFunc(string) ///
         ATTperiods(integer 4) Industry(integer 0) ///
         RHOmat1(string)]
    
    // Default production function type
    if "`pfunc'" == "" {
        local pfunc "translog"
    }
    
    // Validate inputs
    if !inlist("`pfunc'", "translog", "cd") {
        di as error "_pte_mc_dgp: pfunc() must be 'translog' or 'cd'"
        exit 198
    }
    if !inlist(`order', 1, 2, 3) {
        di as error "_pte_mc_dgp: order() must be 1, 2, or 3"
        exit 198
    }
    
    // -----------------------------------------------------------------
    // Extract parameters from input matrices
    // -----------------------------------------------------------------
    // RHO parameters for omega0 (control/untreated state)
    local rho0 = `rhomat'[1, colnumb(`rhomat', "rho0")]
    local rho1 = `rhomat'[1, colnumb(`rhomat', "rho1")]
    if `order' >= 2 {
        local rho2 = `rhomat'[1, colnumb(`rhomat', "rho2")]
    }
    else {
        local rho2 = 0
    }
    if `order' >= 3 {
        local rho3 = `rhomat'[1, colnumb(`rhomat', "rho3")]
    }
    else {
        local rho3 = 0
    }
    
    // RHO parameters for omega1 (treated state)
    // If rhomat1() specified, use independent coefficients; otherwise reuse rhomat
    if "`rhomat1'" != "" {
        // Validate column count matches rhomat
        if colsof(`rhomat1') != colsof(`rhomat') {
            di as error "_pte_mc_dgp: rhomat1() must have same number of columns as rhomat()"
            exit 503
        }
        local rho0_t = `rhomat1'[1, colnumb(`rhomat1', "rho0")]
        local rho1_t = `rhomat1'[1, colnumb(`rhomat1', "rho1")]
        if `order' >= 2 {
            local rho2_t = `rhomat1'[1, colnumb(`rhomat1', "rho2")]
        }
        else {
            local rho2_t = 0
        }
        if `order' >= 3 {
            local rho3_t = `rhomat1'[1, colnumb(`rhomat1', "rho3")]
        }
        else {
            local rho3_t = 0
        }
    }
    else {
        // Backward compatible: omega1 uses same rho as omega0
        local rho0_t = `rho0'
        local rho1_t = `rho1'
        local rho2_t = `rho2'
        local rho3_t = `rho3'
    }
    
    // OMEGA parameters (initial distribution)
    local mu_omega  = `omegamat'[1, 1]
    local sd_omega  = `omegamat'[1, 2]
    
    // =================================================================
    // TASK-001.6: Panel structure — resample from current data
    // =================================================================
    // Reference: DOs/mc_simulation_estimation_experiment.do L56-58
    //   bsample, strata(treat) cluster(firm) idcluster(firm1)
    //   replace firm = firm1
    //   xtset firm year
    // -----------------------------------------------------------------
    
    // Data should already be loaded by the caller (MC loop)
    // Resample with stratification by treatment status
    cap drop treat
    bys firm: egen treat = max(treat_post)
    
    set seed `seed'
    
    // Cluster bootstrap resample preserving treatment structure
    tempvar firm1
    bsample, strata(treat) cluster(firm) idcluster(`firm1')
    qui replace firm = `firm1'
    drop `firm1'
    
    // Re-establish panel structure
    qui tsset firm year
    
    // Store panel dimensions
    qui tab firm
    local n_firms = r(r)
    qui count
    local n_obs = r(N)
    
    // =================================================================
    // TASK-001.7: Treatment status variables
    // =================================================================
    // treat_post should already exist from the source data
    // Regenerate treat (firm-level) after resampling
    // -----------------------------------------------------------------
    
    // treat_yr0 should be inherited from source data
    capture confirm variable treat_yr0
    if _rc {
        di as error "_pte_mc_dgp: treat_yr0 not found in data"
        exit 111
    }
    
    // CRITICAL: Ensure control firms have treat_yr0 = .
    // After bsample, some control firms may retain non-missing treat_yr0
    // from the source data (e.g., treat_yr0 beyond data range).
    // This would cause spurious omega1 initialization.
    qui replace treat_yr0 = . if treat == 0
    
    // =================================================================
    // TASK-001.8: Relative time variable
    // =================================================================
    capture drop _pte_nt
    qui gen int _pte_nt = year - treat_yr0
    qui replace _pte_nt = . if treat == 0
    
    // =================================================================
    // TASK-001.9: Transition period indicator
    // =================================================================
    capture drop mid
    qui gen byte mid = (treat_post != L.treat_post)
    qui replace mid = 0 if missing(L.treat_post)
    
    // =================================================================
    // TASK-001.10: Panel structure validation
    // =================================================================
    // Verify absorbing treatment: D_it >= D_{it-1}
    tempvar d_check
    qui gen byte `d_check' = (treat_post < L.treat_post) if !missing(L.treat_post)
    qui count if `d_check' == 1
    if r(N) > 0 {
        di as error "_pte_mc_dgp: Non-absorbing treatment detected"
        exit 459
    }
    
    // Get time range for evolution loops
    qui sum year
    local first_year = r(min) + 1
    local last_year  = r(max)
    
    // =================================================================
    // TASK-001.11: omega0 initialization — ALL firms at first period
    // =================================================================
    // Reference: pooled DOs/mc_simulation_estimation_experiment_pooled.do L61
    //   bys firm (year): g omega0 = rnormal(OMG_cd[1, 1], OMG_cd[1, 2]) if _n==1
    // DGP initial states must be drawn from omegamat(), not inherited from
    // source omega values in the empirical seed sample.
    // -----------------------------------------------------------------
    
    capture drop omega0
    bys firm (year): gen double omega0 = rnormal(`mu_omega', `sd_omega') if _n == 1
    
    // =================================================================
    // TASK-001.13: omega0 recursive evolution — ALL firms, ALL periods
    // =================================================================
    // Reference: DOs/mc_simulation_estimation_experiment_pooled.do L64
    //   replace omega0 = rho0+rho1*l.omega0 + rnormal(0, EPS[1,1]) if year==time ...
    // The innovation enters in the current period; only the state variable is lagged.
    // -----------------------------------------------------------------
    
    // Pre-draw epsilon shocks for efficiency
    capture drop _pte_eps0
    qui gen double _pte_eps0 = rnormal(0, `sigma_eps0')
    
    // Recursive evolution using by-group sequential replacement
    // Use omega0[_n-1] (sequential within by-group) instead of L.omega0
    // (time-series lag) to handle panel gaps correctly.
    // Reference: DOs/mc_simulation_estimation_experiment_pooled.do L64
    // The reference code's L. operator is on omega0, not on the innovation.
    // We keep [_n-1] for the state variable to handle panel gaps, but the
    // innovation remains current-period, matching the paper/DO recursion.
    if `order' == 1 {
        qui bys firm (year): replace omega0 = `rho0' + `rho1' * omega0[_n-1] ///
            + _pte_eps0 if _n > 1
    }
    else if `order' == 2 {
        qui bys firm (year): replace omega0 = `rho0' + `rho1' * omega0[_n-1] ///
            + `rho2' * (omega0[_n-1])^2 ///
            + _pte_eps0 if _n > 1
    }
    else if `order' == 3 {
        qui bys firm (year): replace omega0 = `rho0' + `rho1' * omega0[_n-1] ///
            + `rho2' * (omega0[_n-1])^2 + `rho3' * (omega0[_n-1])^3 ///
            + _pte_eps0 if _n > 1
    }
    
    // =================================================================
    // TASK-001.12: omega1 initialization — ONLY treated firms at e-1
    // =================================================================
    // FIX: omega1 must inherit from the EVOLVED omega0, not from the
    // population distribution. Drawing from N(mu_omega, sd_omega) causes
    // systematic negative TT because evolved omega0 >> initial mean.
    // Correct: omega1 = omega0 + treatment_shock at treat_yr0 - 1
    // Key constraint: control firms must have omega1 = . (missing)
    // -----------------------------------------------------------------
    
    capture drop omega1
    qui gen double omega1 = omega0 + rnormal(`mu_v', `sigma_v') ///
        if year == treat_yr0 - 1
    
    // Verify: control firms must have omega1 = . everywhere
    qui count if omega1 != . & treat == 0
    if r(N) > 0 {
        di as error "_pte_mc_dgp: CRITICAL — control firms have non-missing omega1"
        exit 459
    }
    
    // =================================================================
    // TASK-001.14: omega1 recursive evolution — CRITICAL time constraint
    // =================================================================
    // Reference: DOs/mc_simulation_estimation_experiment_pooled.do L65
    //   replace omega1 = rho0+tau+rho1*l.omega1 + rnormal(0, EPS[1,2])
    //       if year==time & l.omega1!=. & time>=treat_yr0
    //
    // CRITICAL: The condition `time >= treat_yr0` prevents omega1 from
    // evolving before treatment adoption. Without this constraint,
    // omega1 would incorrectly evolve in pre-treatment periods,
    // making the entire ATT calculation wrong.
    // -----------------------------------------------------------------
    
    capture drop _pte_eps1
    qui gen double _pte_eps1 = rnormal(0, `sigma_eps1')
    
    // omega1 evolution with time constraint: year >= treat_yr0
    // Use omega1[_n-1] for robustness with panel gaps (same as omega0 fix).
    // The tau parameter enters the evolution equation for treated state.
    // Uses rho0_t/rho1_t/rho2_t/rho3_t which come from rhomat1() if specified,
    // or from rhomat() otherwise (backward compatible).
    if `order' == 1 {
        qui bys firm (year): replace omega1 = `rho0_t' + `tau' ///
            + `rho1_t' * omega1[_n-1] ///
            + _pte_eps1 ///
            if _n > 1 & omega1[_n-1] != . & year >= treat_yr0
    }
    else if `order' == 2 {
        qui bys firm (year): replace omega1 = `rho0_t' + `tau' ///
            + `rho1_t' * omega1[_n-1] + `rho2_t' * (omega1[_n-1])^2 ///
            + _pte_eps1 ///
            if _n > 1 & omega1[_n-1] != . & year >= treat_yr0
    }
    else if `order' == 3 {
        qui bys firm (year): replace omega1 = `rho0_t' + `tau' ///
            + `rho1_t' * omega1[_n-1] + `rho2_t' * (omega1[_n-1])^2 ///
            + `rho3_t' * (omega1[_n-1])^3 ///
            + _pte_eps1 ///
            if _n > 1 & omega1[_n-1] != . & year >= treat_yr0
    }
    
    // =================================================================
    // TASK-001.15: Realized productivity omega_true
    // =================================================================
    // omega_true = omega0 if untreated, omega1 if treated
    // Reference: DOs/mc_simulation_estimation_experiment.do L76
    //   g omega_true = omega1*treat_post + omega0*(1-treat_post)
    // -----------------------------------------------------------------
    
    capture drop omega_true
    qui gen double omega_true = omega0
    qui replace omega_true = omega1 if treat_post == 1
    
    // =================================================================
    // TASK-001.16: True treatment effect TT_true
    // =================================================================
    // TT_true = omega1 - omega0 (only defined for treated post-treatment)
    // -----------------------------------------------------------------
    
    capture drop TT_true
    qui gen double TT_true = omega1 - omega0
    
    // =================================================================
    // TASK-001.17: Missing value validation
    // =================================================================
    // Control firms: omega1 = ., TT_true = .
    // -----------------------------------------------------------------
    
    qui count if omega1 != . & treat == 0
    if r(N) > 0 {
        di as error "_pte_mc_dgp: CRITICAL — control firms have non-missing omega1"
        di as error "  Found " r(N) " violations"
        exit 459
    }
    
    qui count if TT_true != . & treat == 0
    if r(N) > 0 {
        di as error "_pte_mc_dgp: CRITICAL — control firms have non-missing TT_true"
        exit 459
    }
    
    // =================================================================
    // TASK-001.18: Numerical stability check
    // =================================================================
    
    qui sum omega0
    if r(max) > 25 | r(min) < -25 {
        di as text "  Warning: omega0 has extreme values [" ///
            %7.2f r(min) ", " %7.2f r(max) "]"
    }
    
    qui sum omega1
    if r(max) > 25 | r(min) < -25 {
        di as text "  Warning: omega1 has extreme values [" ///
            %7.2f r(min) ", " %7.2f r(max) "]"
    }
    
    // =================================================================
    // TASK-001.19~22: Input/output generation
    // =================================================================
    // Reference: DOs/mc_simulation_estimation_experiment.do L73-80
    //   lnk: inherited from resampled data
    //   lnl: inherited from resampled data (already endogenous)
    //   lnm: regenerated from omega_true/current inputs
    //   lny: regenerated using BETA and omega_true
    // -----------------------------------------------------------------
    
    // TASK-001.19: lnk — inherited from source data
    capture confirm variable lnk
    if _rc {
        di as error "_pte_mc_dgp: lnk not found in data"
        exit 111
    }
    
    // TASK-001.20: lnl — inherited from source data
    capture confirm variable lnl
    if _rc {
        di as error "_pte_mc_dgp: lnl not found in data"
        exit 111
    }
    
    // TASK-001.21: lnm — regenerate proxy input following official pooled DOs
    capture confirm variable lnm
    if _rc {
        di as error "_pte_mc_dgp: lnm not found in data"
        exit 111
    }
    capture drop lnm
    if "`pfunc'" == "translog" {
        qui gen double lnm = 0.2 * omega_true + 0.8 * lnk
    }
    else if "`pfunc'" == "cd" {
        qui gen double lnm = 0.2 * omega_true + 0.4 * lnk + 0.4 * lnl ///
            + 0.1 * lnk * lnl
    }
    
    // TASK-001.22: Output lny generation using BETA and omega_true
    // Reference: DOs/mc_simulation_estimation_experiment.do L73-80
    //   gen lny = BETA[i,1]*t + BETA[i,2]*lnl + BETA[i,3]*lnk
    //           + BETA[i,4]*(lnl^2) + BETA[i,5]*(lnk^2) + BETA[i,6]*(lnl*lnk)
    //           + omega0 if treat_post==0
    //   replace lny = ... + omega1 if treat_post==1
    // -----------------------------------------------------------------
    
    capture drop lny
    
    if "`pfunc'" == "translog" {
        // Translog: lny = bt1*t1 + ... + bt6*t6 + bl*lnl + bk*lnk
        //                + bll*lnl^2 + bkk*lnk^2 + blk*lnl*lnk + omega_true + eps_y
        
        // Check if time trend variables exist
        // Reference code uses single 't' variable; pte may use t1..t6 dummies
        capture confirm variable t
        if !_rc {
            // Single time trend (reference code style)
            qui gen double lny = `betamat'[1,1] * t ///
                + `betamat'[1,2] * lnl + `betamat'[1,3] * lnk ///
                + `betamat'[1,4] * (lnl^2) + `betamat'[1,5] * (lnk^2) ///
                + `betamat'[1,6] * (lnl * lnk) ///
                + omega_true + rnormal(0, 0.1)
        }
        else {
            // Time dummies t1..t6 (pte package style)
            // BETA columns: bt1 bt2 bt3 bt4 bt5 bt6 bl bk bll bkk blk
            qui gen double lny = 0
            forv j = 1/6 {
                capture confirm variable t`j'
                if !_rc {
                    qui replace lny = lny + `betamat'[1, `j'] * t`j'
                }
            }
            qui replace lny = lny ///
                + `betamat'[1, 7] * lnl + `betamat'[1, 8] * lnk ///
                + `betamat'[1, 9] * (lnl^2) + `betamat'[1, 10] * (lnk^2) ///
                + `betamat'[1, 11] * (lnl * lnk) ///
                + omega_true + rnormal(0, 0.1)
        }
    }
    else if "`pfunc'" == "cd" {
        // Cobb-Douglas output generation
        // BETA columns vary by specification:
        //   3-col: bt bl bk (with time trend)
        //   2-col: bl bk (no time trend)
        local _beta_ncols = colsof(`betamat')

        if `_beta_ncols' >= 3 {
            // CD with time trend
            capture confirm variable t
            if !_rc {
                qui gen double lny = `betamat'[1,1] * t ///
                    + `betamat'[1,2] * lnl + `betamat'[1,3] * lnk ///
                    + omega_true + rnormal(0, 0.1)
            }
            else {
                capture confirm variable t1
                if !_rc {
                    qui gen double lny = `betamat'[1,1] * t1 ///
                        + `betamat'[1,2] * lnl + `betamat'[1,3] * lnk ///
                        + omega_true + rnormal(0, 0.1)
                }
                else {
                    // No time variable found: skip time trend, use cols 2-3
                    qui gen double lny = `betamat'[1,2] * lnl ///
                        + `betamat'[1,3] * lnk ///
                        + omega_true + rnormal(0, 0.1)
                }
            }
        }
        else if `_beta_ncols' == 2 {
            // CD without time trend: lny = bl*lnl + bk*lnk + omega_true + eps
            qui gen double lny = `betamat'[1,1] * lnl ///
                + `betamat'[1,2] * lnk ///
                + omega_true + rnormal(0, 0.1)
        }
        else {
            di as error "_pte_mc_dgp: CD beta must have 2 or 3 columns, found `_beta_ncols'"
            exit 198
        }
    }
    
    // Generate polynomial variables for estimation
    capture drop k1 l1 m1 k2 l2 m2 l1m1 l1k1 m1k1
    qui gen double l1 = lnl
    qui gen double k1 = lnk
    qui gen double m1 = lnm
    qui gen double l2 = lnl^2
    qui gen double k2 = lnk^2
    qui gen double m2 = lnm^2
    qui gen double l1m1 = lnl * lnm
    qui gen double l1k1 = lnl * lnk
    qui gen double m1k1 = lnm * lnk
    
    // =================================================================
    // TASK-001.23~24: True ATT calculation by relative time
    // =================================================================
    // Reference: DOs/mc_simulation_estimation_experiment.do L82-90
    //   g omg_tt = omega1 - omega0
    //   tabstat omg_att if nt>=0, by(nt) stat(mean) save
    //   matrix ATT_true = (r(Stat1), ..., r(StatTotal))
    // -----------------------------------------------------------------
    
    // Compute TT by firm-nt (already have TT_true = omega1 - omega0)
    // ATT = mean(TT_true) by relative time period nt
    
    tempname ATT_true
    local L = `attperiods'
    
    // Calculate ATT for each relative time period 0..L
    // Plus overall weighted average
    local ncols = `L' + 2  // nt=0,1,...,L plus average
    matrix `ATT_true' = J(1, `ncols', .)
    
    forv ell = 0/`L' {
        qui sum TT_true if _pte_nt == `ell', meanonly
        if r(N) > 0 {
            matrix `ATT_true'[1, `ell' + 1] = r(mean)
        }
    }
    
    // Overall ATT (weighted average across all post-treatment periods)
    qui sum TT_true if _pte_nt >= 0 & _pte_nt <= `L', meanonly
    if r(N) > 0 {
        matrix `ATT_true'[1, `ncols'] = r(mean)
    }
    
    // Set column names
    local cnames ""
    forv ell = 0/`L' {
        local cnames "`cnames' att`ell'"
    }
    local cnames "`cnames' att"
    matrix colnames `ATT_true' = `cnames'
    
    // =================================================================
    // TASK-001.25: Analytical ATT verification (order=1 only)
    // =================================================================
    // For order=1 linear evolution:
    //   ATT_ell = tau * (1 - rho1^(ell+1)) / (1 - rho1)
    // This provides a cross-check against the simulated ATT_true
    // -----------------------------------------------------------------
    
    if `order' == 1 {
        forv ell = 0/`L' {
            local att_analytical = `tau' * (1 - `rho1_t'^(`ell' + 1)) / (1 - `rho1_t')
            local att_simulated = `ATT_true'[1, `ell' + 1]
            local att_diff = abs(`att_simulated' - `att_analytical')
            if `att_diff' > 0.05 {
                di as text "  Note: ATT_`ell' simulated=" ///
                    %7.4f `att_simulated' " analytical=" ///
                    %7.4f `att_analytical' " diff=" %7.4f `att_diff'
            }
        }
    }
    
    // =================================================================
    // TASK-001.26: Result storage and return values
    // =================================================================
    
    // Count treated and control firms
    qui count if treat == 1
    local n_treated_obs = r(N)
    if `n_treated_obs' > 0 {
        qui tab firm if treat == 1
        local n_treated_firms = r(r)
    }
    else {
        local n_treated_firms = 0
    }
    qui count if treat == 0
    if r(N) > 0 {
        qui tab firm if treat == 0
        local n_control_firms = r(r)
    }
    else {
        local n_control_firms = 0
    }
    
    // Clean up temporary variables
    capture drop _pte_eps0
    capture drop _pte_eps1
    capture drop _pte_nt
    
    // Re-establish panel structure after all modifications
    qui tsset firm year
    
    // --- Return matrices ---
    return matrix ATT_true = `ATT_true'
    
    // --- Return scalars ---
    return scalar n_firms     = `n_firms'
    return scalar n_obs       = `n_obs'
    return scalar n_treated   = `n_treated_firms'
    return scalar n_control   = `n_control_firms'
    return scalar tau         = `tau'
    return scalar sigma_eps0  = `sigma_eps0'
    return scalar sigma_eps1  = `sigma_eps1'
    return scalar rho0        = `rho0'
    return scalar rho1        = `rho1'
    return scalar order       = `order'
    return scalar attperiods  = `L'
    return scalar seed        = `seed'
    
end
