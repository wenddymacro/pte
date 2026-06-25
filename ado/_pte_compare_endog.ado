*! version 1.0.0  01jan2026
*! _pte_compare_endog.ado v1.0
*! Endogenous Productivity + TWFE Implementation (Method II)
*! US-E7-009: Endogenous productivity process + TWFE ATT estimation
*!
*! Theory: Paper Section 5, Equation (14)
*! Reference: DOs/prodest_acf_trlg_endog.do, DOs/att_estimation_simulation_r1.do L194-199
*!
*! Key differences from Expost (US-E7-008):
*!   - GMM: 8-column OMEGA_lag_pol (WITH interaction terms)
*!   - Sample: Full sample (no transition period exclusion, same as expost)
*!   - Evolution: h_tilde(omega, D, D_lag) includes treatment interactions
*! Key differences from CLK (pte main):
*!   - Does NOT exclude transition period (mid != 1)
*!   - Uses all observations including D_t != D_{t-1}

version 14.0
capture program drop _pte_compare_endog
program define _pte_compare_endog, eclass
    version 14.0
    
    syntax , treatment(varname) ///
        [SPECs(numlist integer min=1 max=3 >0 <4) ///
         OMEGApoly(integer 3) ///
         ABsorb(string) VCE(string) INDustry(varname) ///
         LAGTreatment DIAGnose noREPort]

    if "`industry'" != "" {
        di as error "Error 198: industry() is not supported by _pte_compare_endog."
        di as error "The released comparison workflow does not implement a general by-industry public interface."
        di as error "Subset the data before calling, or use a dedicated industry comparison workflow."
        exit 198
    }

    // Validate omegapoly range (1-4)
    if `omegapoly' < 1 | `omegapoly' > 4 {
        di as error "Error: omegapoly(`omegapoly') out of range. Must be 1, 2, 3, or 4."
        exit 198
    }
    
    // =========================================================================
    // Step 0: Validate prerequisites
    // =========================================================================
    
    // Check pte has been run
    if "`e(cmd)'" != "pte" {
        di as error "Error 301: pte has not been run."
        di as error "Please run {bf:pte} first, then call {bf:pte_compare}."
        exit 301
    }
    
    // Check reghdfe is installed
    capture which reghdfe
    if _rc {
        di as error "Error 601: reghdfe is required but not installed."
        di as error "Please install: {stata ssc install reghdfe}"
        exit 601
    }
    
    // Save pte results before they get overwritten
    local pte_free    "`e(free)'"
    local pte_state   "`e(state)'"
    local pte_proxy   "`e(proxy)'"
    local pte_depvar  "`e(depvar)'"
    local pte_panelvar "`e(panelvar)'"
    local pte_timevar  "`e(timevar)'"
    local pte_prodfunc "`e(prodfunc)'"
    
    // Default specs: all three (m4, m5, m6 in reproduction code)
    if "`specs'" == "" local specs "1 2 3"
    
    // Default absorb: firm + year FE (paper Eq.18)
    if "`absorb'" == "" local absorb "`pte_panelvar' `pte_timevar'"
    
    // Default VCE: reghdfe default robust
    local vce_opt ""
    if "`vce'" != "" local vce_opt "vce(`vce')"
    
    di as text ""
    di as text "{hline 70}"
    di as text "  Endogenous Productivity (Method II) - US-E7-009"
    di as text "{hline 70}"
    di as text ""
    
    // =========================================================================
    // Step 1: Endogenous ACF Production Function Estimation
    // =========================================================================
    
    di as text "  Step 1: Endogenous ACF production function estimation..."
    di as text "    Key: includes treatment interaction terms, full sample"
    di as text "    omegapoly = `omegapoly' (OMEGA_lag_pol: " 2*`omegapoly'+2 " columns)"
    
    // Preserve data for GMM estimation
    preserve
    
    // Generate polynomial variables for first stage
    // Reference: DOs/prodest_acf_trlg_endog.do L12-25
    local l "`pte_free'"
    local k "`pte_state'"
    local m "`pte_proxy'"
    local y "`pte_depvar'"

    // DOs use a canonical grouped time trend t. Recreate it from the
    // stored pte timevar inside the preserved working sample instead of
    // assuming the caller's dataset already contains a variable named t.
    tempvar _pte_cmp_t
    qui egen `_pte_cmp_t' = group(`pte_timevar')
    capture drop t
    qui gen long t = `_pte_cmp_t'
    label variable t "PTE compare internal grouped time trend"
    
    foreach _v in l1 l2 l3 k1 k2 k3 m1 m2 m3 l1m1 l1k1 m1k1 l1m2 l1k2 m1k2 m1l2 k1l2 k1m2 k1l1m1 {
        cap drop `_v'
    }
    
    qui gen double l1 = `l'
    qui gen double l2 = `l'^2
    qui gen double l3 = `l'^3
    qui gen double k1 = `k'
    qui gen double k2 = `k'^2
    qui gen double k3 = `k'^3
    qui gen double m1 = `m'
    qui gen double m2 = `m'^2
    qui gen double m3 = `m'^3
    qui gen double l1m1 = `l' * `m'
    qui gen double l1k1 = `l' * `k'
    qui gen double m1k1 = `m' * `k'
    qui gen double l1m2 = `l' * `m'^2
    qui gen double l1k2 = `l' * `k'^2
    qui gen double m1k2 = `m' * `k'^2
    qui gen double m1l2 = `m' * `l'^2
    qui gen double k1l2 = `k' * `l'^2
    qui gen double k1m2 = `k' * `m'^2
    qui gen double k1l1m1 = `k' * `m' * `l'
    
    // First-stage regression: phi = E[y | l_poly, k_poly, m_poly, t]
    // Reference: DOs/prodest_acf_trlg_endog.do L28-30
    qui reg `y' l1* m1* k1* k2* l2* m2* k3 l3 m3 t
    cap drop phi
    qui predict double phi
    
    // Remove time trend (subtract controls, NOT input variables)
    scalar _pte_beta_t_endog = _b[t]
    qui replace phi = phi - _pte_beta_t_endog * t
    
    // OLS initial values for GMM
    qui reg `y' `l' `k' l2 k2 l1k1 t
    
    // Ensure panel is set
    qui xtset `pte_panelvar' `pte_timevar'
    
    // Generate lagged variables for GMM
    // Reference: DOs/prodest_acf_trlg_endog.do L44-51
    cap drop *_lag
    foreach var in phi `k' `l' `m' l2 k2 l1k1 `treatment' _pte_mid {
        cap gen double `var'_lag = L.`var'
    }
    // Mixed lag instrument: l_{t-1} * k_t (capital is state variable)
    cap drop kl_lag
    qui gen double kl_lag = `l'_lag * `k'
    qui gen double const = 1
    
    // Generate treat_post_lag for Mata (interaction term variable)
    // Reference: DOs/prodest_acf_trlg_endog.do L48 (treat_post in foreach)
    // Note: When treatment="treat_post", the foreach loop above already
    // created treat_post_lag. Only recreate if it doesn't exist or if the
    // treatment variable has a different name.
    capture confirm variable treat_post_lag
    if _rc {
        qui gen double treat_post_lag = L.`treatment'
    }
    
    // Drop first period (no lag available)
    // Reference: DOs/prodest_acf_trlg_endog.do L51
    // NOTE: Do NOT drop transition period - this is the key difference from CLK
    qui bys `pte_panelvar' (t): drop if _n == 1
    
    // Rename for Mata compatibility without recomputing lags after sample trimming.
    // FIX: When free="lnl" or state="lnk", the alias IS the source variable.
    // Dropping then recreating from itself causes rc=111 "not found".
    if "`l'" != "lnl" {
        capture drop lnl
        capture drop lnl_lag
        qui gen double lnl = `l'
        qui gen double lnl_lag = `l'_lag
    }
    if "`k'" != "lnk" {
        capture drop lnk
        capture drop lnk_lag
        qui gen double lnk = `k'
        qui gen double lnk_lag = `k'_lag
    }
    
    // Drop observations with missing lags
    qui drop if missing(phi_lag) | missing(lnl_lag) | missing(lnk_lag)
    qui drop if missing(treat_post_lag)
    
    di as text "    First stage: phi estimated (N = " _N ")"
    
    // =========================================================================
    // Step 1b: GMM Estimation (Mata)
    // =========================================================================
    
    // Compile and run Mata GMM
    cap mata: mata drop _pte_gmm_endog()
    cap mata: mata drop _pte_model_endog()
    
    // Find the mata file via adopath
    local mata_file ""
    cap qui findfile _pte_compare_endog_gmm.mata
    if !_rc {
        local mata_file "`r(fn)'"
    }
    else {
        // Fallback: check relative paths
        foreach dir in "." "ado" {
            cap confirm file "`dir'/_pte_compare_endog_gmm.mata"
            if !_rc {
                local mata_file "`dir'/_pte_compare_endog_gmm.mata"
                continue, break
            }
        }
    }
    
    if "`mata_file'" == "" {
        di as error "Error: Cannot find _pte_compare_endog_gmm.mata"
        exit 601
    }
    
    qui do "`mata_file'"
    
    // Set omegapoly scalar for Mata to read
    scalar _pte_omegapoly_endog = `omegapoly'
    
    // Run GMM optimization
    mata: _pte_model_endog()
    
    // Extract results
    tempname beta_endog
    matrix `beta_endog' = _pte_beta_endog
    local fval_endog = _pte_fval_endog
    
    // Name the columns
    matrix colnames `beta_endog' = beta_l beta_k beta_ll beta_kk beta_lk
    
    scalar _pte_endog_bl  = `beta_endog'[1, 1]
    scalar _pte_endog_bk  = `beta_endog'[1, 2]
    scalar _pte_endog_bll = `beta_endog'[1, 3]
    scalar _pte_endog_bkk = `beta_endog'[1, 4]
    scalar _pte_endog_blk = `beta_endog'[1, 5]
    
    di as text "    GMM converged: fval = " %12.8f `fval_endog'
    di as text "    beta_l = " %9.6f _pte_endog_bl ///
               "  beta_k = " %9.6f _pte_endog_bk
    
    restore
    
    // =========================================================================
    // Step 2: Productivity Recovery
    // =========================================================================
    
    di as text ""
    di as text "  Step 2: Recovering endogenous productivity (omega_end)..."
    
    // omega_end = phi - beta_l*l - beta_k*k - beta_ll*l^2 - beta_kk*k^2 - beta_lk*l*k
    // Reference: DOs/att_estimation_simulation_r1.do L162
    
    cap drop _pte_omega_end _pte_omega_end2 _pte_omega_end3
    
    qui gen double _pte_omega_end = _pte_phi ///
        - _pte_endog_bl  * `pte_free' ///
        - _pte_endog_bk  * `pte_state' ///
        - _pte_endog_bll * `pte_free'^2 ///
        - _pte_endog_bkk * `pte_state'^2 ///
        - _pte_endog_blk * `pte_free' * `pte_state'
    
    // Generate polynomial terms
    // Reference: DOs/att_estimation_simulation_r1.do L179-180
    qui gen double _pte_omega_end2 = _pte_omega_end^2
    qui gen double _pte_omega_end3 = _pte_omega_end^3
    
    label variable _pte_omega_end  "Endogenous productivity (omega_end)"
    label variable _pte_omega_end2 "omega_end squared"
    label variable _pte_omega_end3 "omega_end cubed"
    
    qui count if !missing(_pte_omega_end)
    di as text "    omega_end recovered: N = " r(N)
    
    // =========================================================================
    // Step 3: TWFE Regressions (m4, m5, m6 in reproduction code)
    // =========================================================================
    
    di as text ""
    di as text "  Step 3: TWFE regressions..."
    
    // Ensure panel is set
    qui xtset `pte_panelvar' `pte_timevar'
    
    // Determine treatment variable
    // Default: L.D_it (reproduction code uses L.treat_post for m4-m6)
    // Reference: DOs/att_estimation_simulation_r1.do L194-199
    local treat_var "L.`treatment'"
    if "`lagtreatment'" == "" {
        // Default for endogenous method: use L.treatment per reproduction code
        di as text "    Using L.`treatment' (lagged treatment, per reproduction code)"
    }
    else {
        di as text "    Using L.`treatment' (lagged treatment)"
    }
    di as text "    Absorb: `absorb'"
    
    // Initialize result matrices
    tempname coef_mat se_mat ci_mat r2_mat n_mat
    matrix `coef_mat' = J(1, 3, .)
    matrix `se_mat'   = J(1, 3, .)
    matrix `ci_mat'   = J(3, 2, .)
    matrix `r2_mat'   = J(1, 3, .)
    matrix `n_mat'    = J(1, 3, .)
    
    // Run each specification
    // Reference: DOs/att_estimation_simulation_r1.do L194-199
    foreach s of local specs {
        
        if `s' == 1 {
            // Spec 1 (m4): No controls
            // reghdfe omega_end L.treat_post, absorb(indid_adj year)
            qui reghdfe _pte_omega_end `treat_var', ///
                absorb(`absorb') `vce_opt'
            
            matrix `coef_mat'[1, 1] = _b[`treat_var']
            matrix `se_mat'[1, 1]   = _se[`treat_var']
            matrix `ci_mat'[1, 1]   = _b[`treat_var'] - 1.96 * _se[`treat_var']
            matrix `ci_mat'[1, 2]   = _b[`treat_var'] + 1.96 * _se[`treat_var']
            matrix `r2_mat'[1, 1]   = e(r2_a)
            matrix `n_mat'[1, 1]    = e(N)
            
            estimates store _endog_m4
            
            di as text "    Spec 1/m4 (no control): delta = " ///
                %9.4f `coef_mat'[1,1] " (SE = " %9.4f `se_mat'[1,1] ")"
        }
        
        if `s' == 2 {
            // Spec 2 (m5): 1st order lag
            // reghdfe omega_end L.omega_end L.treat_post, absorb(indid_adj year)
            qui reghdfe _pte_omega_end L._pte_omega_end `treat_var', ///
                absorb(`absorb') `vce_opt'
            
            matrix `coef_mat'[1, 2] = _b[`treat_var']
            matrix `se_mat'[1, 2]   = _se[`treat_var']
            matrix `ci_mat'[2, 1]   = _b[`treat_var'] - 1.96 * _se[`treat_var']
            matrix `ci_mat'[2, 2]   = _b[`treat_var'] + 1.96 * _se[`treat_var']
            matrix `r2_mat'[1, 2]   = e(r2_a)
            matrix `n_mat'[1, 2]    = e(N)
            
            estimates store _endog_m5
            
            di as text "    Spec 2/m5 (1st order): delta = " ///
                %9.4f `coef_mat'[1,2] " (SE = " %9.4f `se_mat'[1,2] ")"
        }
        
        if `s' == 3 {
            // Spec 3 (m6): 3rd order polynomial
            // reghdfe omega_end L.omega_end L.omega_end2 L.omega_end3 L.treat_post, absorb(indid_adj year)
            qui reghdfe _pte_omega_end L._pte_omega_end ///
                L._pte_omega_end2 L._pte_omega_end3 `treat_var', ///
                absorb(`absorb') `vce_opt'
            
            matrix `coef_mat'[1, 3] = _b[`treat_var']
            matrix `se_mat'[1, 3]   = _se[`treat_var']
            matrix `ci_mat'[3, 1]   = _b[`treat_var'] - 1.96 * _se[`treat_var']
            matrix `ci_mat'[3, 2]   = _b[`treat_var'] + 1.96 * _se[`treat_var']
            matrix `r2_mat'[1, 3]   = e(r2_a)
            matrix `n_mat'[1, 3]    = e(N)
            
            estimates store _endog_m6
            
            di as text "    Spec 3/m6 (3rd order): delta = " ///
                %9.4f `coef_mat'[1,3] " (SE = " %9.4f `se_mat'[1,3] ")"
        }
    }
    
    // =========================================================================
    // Step 4: Results Output
    // =========================================================================
    
    if "`report'" != "noreport" {
        di as text ""
        di as text "{hline 70}"
        di as text "  Endogenous Productivity TWFE Results (Method II)"
        di as text "{hline 70}"
        di as text ""
        di as text "  Production function: Translog (endogenous productivity)"
        di as text "  GMM: " 2*`omegapoly'+2 "-column OMEGA_lag_pol (with treatment interactions, omegapoly=`omegapoly')"
        di as text "  Sample: Full (transition period NOT excluded)"
        di as text "  Absorb: `absorb'"
        di as text "  Treatment: L.`treatment' (lagged)"
        di as text ""
        di as text "  {hline 66}"
        di as text "                        No Control    1st Order    3rd Order"
        di as text "                          (m4)          (m5)          (m6)"
        di as text "  {hline 66}"
        
        // Treatment coefficient
        di as text "  Treatment effect     " ///
            %9.4f `coef_mat'[1,1] ///
            "      " %9.4f `coef_mat'[1,2] ///
            "      " %9.4f `coef_mat'[1,3]
        
        // Standard errors
        di as text "                       (" ///
            %7.4f `se_mat'[1,1] ")    (" ///
            %7.4f `se_mat'[1,2] ")    (" ///
            %7.4f `se_mat'[1,3] ")"
        
        // Significance stars
        local stars1 ""
        local stars2 ""
        local stars3 ""
        forvalues s = 1/3 {
            if `se_mat'[1,`s'] != . & `se_mat'[1,`s'] > 0 {
                local p = 2 * (1 - normal(abs(`coef_mat'[1,`s'] / `se_mat'[1,`s'])))
                if `p' < 0.01      local stars`s' "***"
                else if `p' < 0.05 local stars`s' "**"
                else if `p' < 0.10 local stars`s' "*"
            }
        }
        di as text "  Significance         " ///
            _col(26) "`stars1'" ///
            _col(39) "`stars2'" ///
            _col(52) "`stars3'"
        
        // Sample size
        di as text "  N                    " ///
            %9.0f `n_mat'[1,1] ///
            "      " %9.0f `n_mat'[1,2] ///
            "      " %9.0f `n_mat'[1,3]
        
        // Adjusted R-squared
        di as text "  Adj. R-squared       " ///
            %9.4f `r2_mat'[1,1] ///
            "      " %9.4f `r2_mat'[1,2] ///
            "      " %9.4f `r2_mat'[1,3]
        
        di as text "  {hline 66}"
        di as text "  Note: * p<0.10, ** p<0.05, *** p<0.01"
        
        // Bias analysis (if diagnose option)
        if "`diagnose'" != "" {
            di as text ""
            di as text "  Bias Sources (Paper Section 5, Equation 14):"
            di as text "  {hline 66}"
            di as text "  Problem 1 (Unobserved Heterogeneity):"
            di as text "    Firms observe (omega0, omega1) but econometrician only omega"
            di as text "    Selection into treatment depends on potential outcomes"
            di as text ""
            di as text "  Problem 2 (Causal Misinterpretation):"
            di as text "    h_tilde(omega, D=1, D_lag=0) conflates selection + treatment"
            di as text "    Cannot separate causal effect from selection bias"
            di as text ""
            di as text "  Problem 3 (Misleading ATE):"
            di as text "    Conditional unconfoundedness fails at transition"
            di as text "    TWFE delta != ATT even with correct controls"
            di as text ""
            di as text "  Expected Bias (Table E.5):"
            di as text "    m4 (no control): POSITIVE bias (overestimate)"
            di as text "    m5/m6 (with controls): NEGATIVE bias (underestimate)"
            di as text "  {hline 66}"
        }
        
        di as text "{hline 70}"
    }
    
    // =========================================================================
    // Step 5: Store e() return values
    // =========================================================================
    
    // Name matrices
    matrix colnames `coef_mat' = spec1 spec2 spec3
    matrix colnames `se_mat'   = spec1 spec2 spec3
    matrix rownames `ci_mat'   = spec1 spec2 spec3
    matrix colnames `ci_mat'   = ci_lower ci_upper
    matrix colnames `r2_mat'   = spec1 spec2 spec3
    matrix colnames `n_mat'    = spec1 spec2 spec3
    
    ereturn clear
    ereturn post, esample()
    
    // Scalars
    ereturn scalar att_endog_1 = `coef_mat'[1, 1]
    ereturn scalar att_endog_2 = `coef_mat'[1, 2]
    ereturn scalar att_endog_3 = `coef_mat'[1, 3]
    ereturn scalar se_endog_1  = `se_mat'[1, 1]
    ereturn scalar se_endog_2  = `se_mat'[1, 2]
    ereturn scalar se_endog_3  = `se_mat'[1, 3]
    ereturn scalar fval_endog  = `fval_endog'
    ereturn scalar omegapoly   = `omegapoly'
    
    // Build compare matrices BEFORE ereturn moves the originals away
    tempname compare_coef compare_se
    matrix `compare_coef' = `coef_mat'
    matrix `compare_se'   = `se_mat'
    matrix colnames `compare_coef' = spec1 spec2 spec3
    matrix colnames `compare_se'   = spec1 spec2 spec3

    // Matrices (ereturn matrix MOVES them out of regular namespace)
    ereturn matrix coef_endog  = `coef_mat'
    ereturn matrix se_endog    = `se_mat'
    ereturn matrix ci_endog    = `ci_mat'
    ereturn matrix r2_endog    = `r2_mat'
    ereturn matrix n_endog     = `n_mat'
    ereturn matrix beta_endog  = `beta_endog'
    ereturn matrix compare_coef = `compare_coef'
    ereturn matrix compare_se   = `compare_se'
    
    // Strings
    ereturn local cmd "pte_compare"
    ereturn local method "endog"
    ereturn local treatment "`treatment'"
    ereturn local absorb "`absorb'"
    ereturn local specs "`specs'"
    
end
