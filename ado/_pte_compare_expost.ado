*! version 1.0.0  01jan2026
*! _pte_compare_expost.ado v1.0
*! Ex-post Regression + TWFE Implementation (Method I)
*! US-E7-008: Exogenous productivity process + TWFE ATT estimation
*!
*! Theory: Paper Section 5, Section 6.4.3, Equations (18)-(19)
*! Reference: DOs/prodest_acf_trlg_exog.do, DOs/att_estimation_simulation_r1.do L143-254
*!
*! Key differences from CLK (pte main):
*!   - GMM: 4-column OMEGA_lag_pol (no interaction terms)
*!   - Sample: Full sample (no transition period exclusion)
*!   - Evolution: h_bar_0 = h_bar_1 (forced equal)
*!   - ATT: TWFE regression instead of counterfactual simulation

version 14.0
capture program drop _pte_compare_expost
program define _pte_compare_expost, eclass
    version 14.0
    
    syntax , treatment(varname) ///
        [SPECs(numlist integer min=1 max=3 >0 <4) ///
         ABsorb(string) VCE(string) INDustry(varname) ///
         LAGTreatment DIAGnose noREPort]

    if "`industry'" != "" {
        di as error "Error 198: industry() is not supported by _pte_compare_expost."
        di as error "The released comparison workflow does not implement a general by-industry public interface."
        di as error "Subset the data before calling, or use a dedicated industry comparison workflow."
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
    
    // Default specs: all three
    if "`specs'" == "" local specs "1 2 3"
    
    // Default absorb: firm + year FE (paper Eq.18, 疑点53 confirmed)
    if "`absorb'" == "" local absorb "`pte_panelvar' `pte_timevar'"
    
    // Default VCE: reghdfe default robust (疑点55 resolved)
    local vce_opt ""
    if "`vce'" != "" local vce_opt "vce(`vce')"
    
    di as text ""
    di as text "{hline 70}"
    di as text "  Ex-post Regression (Method I) - US-E7-008"
    di as text "{hline 70}"
    di as text ""
    
    // =========================================================================
    // Step 1: Ex-post ACF Production Function Estimation
    // =========================================================================
    
    di as text "  Step 1: Ex-post ACF production function estimation..."
    
    // Preserve data for GMM estimation
    preserve
    
    // Generate polynomial variables for first stage
    // Reference: DOs/prodest_acf_trlg_exog.do L12-25
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
    // Reference: DOs/prodest_acf_trlg_exog.do L28-30
    qui reg `y' l1* m1* k1* k2* l2* m2* k3 l3 m3 t
    cap drop phi
    qui predict double phi
    
    // Remove time trend (subtract controls, NOT input variables)
    scalar _pte_beta_t_expost = _b[t]
    qui replace phi = phi - _pte_beta_t_expost * t
    
    // OLS initial values for GMM
    qui reg `y' `l' `k' l2 k2 l1k1 t
    
    // Ensure panel is set
    qui xtset `pte_panelvar' `pte_timevar'
    
    // Generate lagged variables for GMM
    // Reference: DOs/prodest_acf_trlg_exog.do L46-52
    cap drop *_lag
    foreach var in phi `k' `l' `m' l2 k2 l1k1 `treatment' _pte_mid {
        cap gen double `var'_lag = L.`var'
    }
    // Mixed lag instrument: l_{t-1} * k_t (capital is state variable)
    cap drop kl_lag
    qui gen double kl_lag = `l'_lag * `k'
    qui gen double const = 1
    
    // Drop first period (no lag available)
    // Reference: DOs/prodest_acf_trlg_exog.do L53
    qui bys `pte_panelvar' (t): drop if _n == 1
    
    // Rename for Mata compatibility
    // Mata reads: lnl, lnk, l2, k2, l1k1, phi, phi_lag, etc.
    // FIX: When free="lnl" or state="lnk", the alias IS the source variable.
    // Dropping then recreating from itself causes rc=111 "not found".
    // Only drop/recreate aliases that differ from the source variable name.
    capture drop l2_lag
    capture drop k2_lag
    capture drop l1k1_lag
    capture drop phi_lag
    qui sort `pte_panelvar' `pte_timevar'
    qui gen double l2_lag = L.l2
    qui gen double k2_lag = L.k2
    qui gen double l1k1_lag = L.l1k1
    qui gen double phi_lag = L.phi
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
    
    // NOTE: Do NOT drop transition period - this is the key difference from CLK
    // Ex-post method uses full sample
    
    di as text "    First stage: phi estimated (N = " _N ")"
    
    // =========================================================================
    // Step 1b: GMM Estimation (Mata)
    // =========================================================================
    
    // Compile and run Mata GMM
    // The Mata file defines _pte_gmm_expost() and _pte_model_expost()
    cap mata: mata drop _pte_gmm_expost()
    cap mata: mata drop _pte_model_expost()
    
    // Find the mata file via adopath
    local mata_file ""
    cap qui findfile _pte_compare_expost_gmm.mata
    if !_rc {
        local mata_file "`r(fn)'"
    }
    else {
        // Fallback: check relative paths
        foreach dir in "." "ado" {
            cap confirm file "`dir'/_pte_compare_expost_gmm.mata"
            if !_rc {
                local mata_file "`dir'/_pte_compare_expost_gmm.mata"
                continue, break
            }
        }
    }
    
    if "`mata_file'" == "" {
        di as error "Error: Cannot find _pte_compare_expost_gmm.mata"
        exit 601
    }
    
    qui do "`mata_file'"
    
    // Run GMM optimization
    mata: _pte_model_expost()
    
    // Extract results
    tempname beta_expost
    matrix `beta_expost' = _pte_beta_expost
    local fval_expost = _pte_fval_expost
    
    // Name the columns
    matrix colnames `beta_expost' = beta_l beta_k beta_ll beta_kk beta_lk
    
    scalar _pte_expost_bl  = `beta_expost'[1, 1]
    scalar _pte_expost_bk  = `beta_expost'[1, 2]
    scalar _pte_expost_bll = `beta_expost'[1, 3]
    scalar _pte_expost_bkk = `beta_expost'[1, 4]
    scalar _pte_expost_blk = `beta_expost'[1, 5]
    
    di as text "    GMM converged: fval = " %12.8f `fval_expost'
    di as text "    beta_l = " %9.6f _pte_expost_bl ///
               "  beta_k = " %9.6f _pte_expost_bk
    
    restore
    
    // =========================================================================
    // Step 2: Productivity Recovery
    // =========================================================================
    
    di as text ""
    di as text "  Step 2: Recovering ex-post productivity (omega_exg)..."
    
    // omega_exg = phi - beta_l*l - beta_k*k - beta_ll*l^2 - beta_kk*k^2 - beta_lk*l*k
    // Reference: DOs/att_estimation_simulation_r1.do L157
    
    cap drop _pte_omega_exg _pte_omega_exg2 _pte_omega_exg3
    
    qui gen double _pte_omega_exg = _pte_phi ///
        - _pte_expost_bl  * `pte_free' ///
        - _pte_expost_bk  * `pte_state' ///
        - _pte_expost_bll * `pte_free'^2 ///
        - _pte_expost_bkk * `pte_state'^2 ///
        - _pte_expost_blk * `pte_free' * `pte_state'
    
    // Generate polynomial terms
    // Reference: DOs/att_estimation_simulation_r1.do L179-180
    qui gen double _pte_omega_exg2 = _pte_omega_exg^2
    qui gen double _pte_omega_exg3 = _pte_omega_exg^3
    
    label variable _pte_omega_exg  "Ex-post productivity (omega_exg)"
    label variable _pte_omega_exg2 "omega_exg squared"
    label variable _pte_omega_exg3 "omega_exg cubed"
    
    qui count if !missing(_pte_omega_exg)
    di as text "    omega_exg recovered: N = " r(N)
    
    // =========================================================================
    // Step 3: TWFE Regressions
    // =========================================================================
    
    di as text ""
    di as text "  Step 3: TWFE regressions..."
    
    // Ensure panel is set
    qui xtset `pte_panelvar' `pte_timevar'
    
    // Determine treatment variable
    // Default: current period D_it (paper Eq.18, 疑点54 confirmed)
    // lagtreatment option: L.D for replication compatibility
    local treat_var "`treatment'"
    if "`lagtreatment'" != "" {
        tempvar L_treat
        qui gen double `L_treat' = L.`treatment'
        local treat_var "`L_treat'"
        di as text "    Using lagged treatment (L.`treatment') for replication"
    }
    else {
        di as text "    Using current treatment (`treatment') per paper Eq.(18)"
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
    // Reference: DOs/att_estimation_simulation_r1.do L188-204
    foreach s of local specs {
        
        if `s' == 1 {
            // Spec 1: No controls (m1)
            // reghdfe omega_exg [L.]treat_post, absorb(firm year)
            qui reghdfe _pte_omega_exg `treat_var', ///
                absorb(`absorb') `vce_opt'
            
            matrix `coef_mat'[1, 1] = _b[`treat_var']
            matrix `se_mat'[1, 1]   = _se[`treat_var']
            matrix `ci_mat'[1, 1]   = _b[`treat_var'] - 1.96 * _se[`treat_var']
            matrix `ci_mat'[1, 2]   = _b[`treat_var'] + 1.96 * _se[`treat_var']
            matrix `r2_mat'[1, 1]   = e(r2_a)
            matrix `n_mat'[1, 1]    = e(N)
            
            estimates store _expost_m1
            
            di as text "    Spec 1 (no control): delta = " ///
                %9.4f `coef_mat'[1,1] " (SE = " %9.4f `se_mat'[1,1] ")"
        }
        
        if `s' == 2 {
            // Spec 2: 1st order lag (m2)
            // reghdfe omega_exg L.omega_exg [L.]treat_post, absorb(firm year)
            qui reghdfe _pte_omega_exg L._pte_omega_exg `treat_var', ///
                absorb(`absorb') `vce_opt'
            
            matrix `coef_mat'[1, 2] = _b[`treat_var']
            matrix `se_mat'[1, 2]   = _se[`treat_var']
            matrix `ci_mat'[2, 1]   = _b[`treat_var'] - 1.96 * _se[`treat_var']
            matrix `ci_mat'[2, 2]   = _b[`treat_var'] + 1.96 * _se[`treat_var']
            matrix `r2_mat'[1, 2]   = e(r2_a)
            matrix `n_mat'[1, 2]    = e(N)
            
            estimates store _expost_m2
            
            di as text "    Spec 2 (1st order): delta = " ///
                %9.4f `coef_mat'[1,2] " (SE = " %9.4f `se_mat'[1,2] ")"
        }
        
        if `s' == 3 {
            // Spec 3: 3rd order polynomial (m3)
            // reghdfe omega_exg L.omega_exg L.omega_exg2 L.omega_exg3 [L.]treat_post, absorb(firm year)
            qui reghdfe _pte_omega_exg L._pte_omega_exg ///
                L._pte_omega_exg2 L._pte_omega_exg3 `treat_var', ///
                absorb(`absorb') `vce_opt'
            
            matrix `coef_mat'[1, 3] = _b[`treat_var']
            matrix `se_mat'[1, 3]   = _se[`treat_var']
            matrix `ci_mat'[3, 1]   = _b[`treat_var'] - 1.96 * _se[`treat_var']
            matrix `ci_mat'[3, 2]   = _b[`treat_var'] + 1.96 * _se[`treat_var']
            matrix `r2_mat'[1, 3]   = e(r2_a)
            matrix `n_mat'[1, 3]    = e(N)
            
            estimates store _expost_m3
            
            di as text "    Spec 3 (3rd order): delta = " ///
                %9.4f `coef_mat'[1,3] " (SE = " %9.4f `se_mat'[1,3] ")"
        }
    }
    
    // =========================================================================
    // Step 4: Results Output
    // =========================================================================
    
    if "`report'" != "noreport" {
        di as text ""
        di as text "{hline 70}"
        di as text "  Ex-post TWFE Results (Method I)"
        di as text "{hline 70}"
        di as text ""
        di as text "  Production function: Translog (exogenous productivity)"
        di as text "  Absorb: `absorb'"
        if "`lagtreatment'" != "" {
            di as text "  Treatment: L.`treatment' (lagged)"
        }
        else {
            di as text "  Treatment: `treatment' (current period)"
        }
        di as text ""
        di as text "  {hline 66}"
        di as text "                        No Control    1st Order    3rd Order"
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
            local p = 2 * (1 - normal(abs(`coef_mat'[1,`s'] / `se_mat'[1,`s'])))
            if `p' < 0.01      local stars`s' "***"
            else if `p' < 0.05 local stars`s' "**"
            else if `p' < 0.10 local stars`s' "*"
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
        
        // T4.3: Bias analysis report (Paper Section 5)
        if "`diagnose'" != "" {
            di as text ""
            di as text "  Bias Source Analysis (Paper Section 5):"
            di as text "  {hline 66}"
            di as text "  Problem 1 (Unobserved Heterogeneity):      YES"
            di as text "    Firm observes (omega0, omega1) but econometrician"
            di as text "    only observes realized omega. Selection into treatment"
            di as text "    depends on potential outcomes -> omitted variable bias."
            di as text ""
            di as text "  Problem 2 (Misleading Causal Interpretation): YES"
            di as text "    Exogenous process forces h0 = h1, conflating"
            di as text "    instantaneous effect with dynamic evolution."
            di as text "    Cannot separate causal effect from selection."
            di as text ""
            di as text "  Problem 3 (Misleading ATE):                YES"
            di as text "    TWFE estimates ATE (average over all firms),"
            di as text "    not ATT on the treated. Conditional unconfoundedness"
            di as text "    fails at transition period."
            di as text ""
            di as text "  Expected Bias Direction (Table E.5):"
            di as text "    Spec 1 (no control):  POSITIVE (overestimate)"
            di as text "      Selection effect dominates without controls."
            di as text "    Spec 2/3 (with lags): NEGATIVE (underestimate)"
            di as text "      Lag controls absorb dynamics, attenuate effect."
            di as text "  {hline 66}"
            
            // Quantitative bias vs pte ATT (if available)
            capture confirm matrix e(att)
            if !_rc {
                tempname att_pte
                matrix `att_pte' = e(att)
                local ncols_att = colsof(`att_pte')
                local att_sum = 0
                local att_cnt = `ncols_att'
                if `ncols_att' > 1 local att_cnt = `ncols_att' - 1
                forvalues j = 1/`att_cnt' {
                    local att_sum = `att_sum' + `att_pte'[1, `j']
                }
                local att_mean = `att_sum' / `att_cnt'
                
                di as text ""
                di as text "  Quantitative Bias (vs pte ATT mean):"
                di as text "  pte ATT mean:  " %10.6f `att_mean'
                forvalues s = 1/3 {
                    if `coef_mat'[1, `s'] != . {
                        local bias_abs = `coef_mat'[1, `s'] - `att_mean'
                        local bias_pct = .
                        if abs(`att_mean') > 1e-10 {
                            local bias_pct = `bias_abs' / `att_mean' * 100
                        }
                        di as text "  Spec `s':        " ///
                            %10.6f `coef_mat'[1, `s'] ///
                            "  bias = " %8.4f `bias_abs' ///
                            " (" %6.1f `bias_pct' "%)"
                    }
                }
            }
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
    ereturn scalar att_expost_1 = `coef_mat'[1, 1]
    ereturn scalar att_expost_2 = `coef_mat'[1, 2]
    ereturn scalar att_expost_3 = `coef_mat'[1, 3]
    ereturn scalar se_expost_1  = `se_mat'[1, 1]
    ereturn scalar se_expost_2  = `se_mat'[1, 2]
    ereturn scalar se_expost_3  = `se_mat'[1, 3]
    ereturn scalar fval_expost  = `fval_expost'
    
    // Matrices
    ereturn matrix coef_expost  = `coef_mat'
    ereturn matrix se_expost    = `se_mat'
    ereturn matrix ci_expost    = `ci_mat'
    ereturn matrix r2_expost    = `r2_mat'
    ereturn matrix n_expost     = `n_mat'
    ereturn matrix beta_expost  = `beta_expost'
    
    // T5.5: compare_coef/compare_se for US-011 chart interface
    tempname compare_coef compare_se
    matrix `compare_coef' = J(1, 3, .)
    matrix `compare_se'   = J(1, 3, .)
    forvalues s = 1/3 {
        matrix `compare_coef'[1, `s'] = e(att_expost_`s')
        matrix `compare_se'[1, `s']   = e(se_expost_`s')
    }
    matrix colnames `compare_coef' = spec1 spec2 spec3
    matrix colnames `compare_se'   = spec1 spec2 spec3
    ereturn matrix compare_coef = `compare_coef'
    ereturn matrix compare_se   = `compare_se'
    
    // Strings
    ereturn local cmd "pte_compare"
    ereturn local method "expost"
    ereturn local treatment "`treatment'"
    ereturn local absorb "`absorb'"
    ereturn local specs "`specs'"
    if "`lagtreatment'" != "" ereturn local lagtreatment "lagtreatment"
    
end
