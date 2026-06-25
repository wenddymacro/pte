*! _pte_mc_engine.ado  v1.1.0
*! Monte Carlo simulation engine for pte
*! Implements outer MC loop: DGP generation -> estimation -> evaluation
*! v1.1.0: Added compare option for Method I/II comparison via pte_compare

version 14.0
capture program drop _pte_mc_engine
program define _pte_mc_engine, rclass
    version 14.0
    local _pte_mc_optscan `"`0'"'
    syntax, NSim(integer) ///
        BETAmat(string) RHOmat(string) OMEGAmat(string) ///
        [TAU(real 0.06) Sigma_eps0(real 0.2) Sigma_eps1(real 0.1) ///
         Mu_v(real 0.05) Sigma_v(real 0.1) ///
         Order(integer 1) PFunc(string) ///
         ATTperiods(integer 4) ///
         Seed(integer 10000) ATTseed(integer 20000) BOOTseed(integer 20000) ///
         NBoot(integer 0) ///
         NOEstimate SAVing(string) ///
         Free(string) Proxy(string) State(string) ///
         Control(string) Treatment(string) ///
         COMpare RHOmat1(string)]

    // =========================================================================
    // 0. Validate inputs and load Mata helpers
    // =========================================================================
    if `nsim' < 1 {
        di as error "_pte_mc_engine: nsim must be >= 1"
        exit 198
    }
    if `attperiods' < 1 {
        di as error "_pte_mc_engine: attperiods must be >= 1"
        exit 198
    }
    if `bootseed' < 1 {
        di as error "_pte_mc_engine: bootseed must be >= 1"
        exit 198
    }
    if `bootseed' > 2147483647 {
        di as error "_pte_mc_engine: bootseed exceeds maximum value (2147483647)"
        exit 198
    }
    if `nboot' > 0 & `bootseed' > 2147483647 - `nboot' + 1 {
        di as error "_pte_mc_engine: bootseed() is too large for nboot(`nboot')"
        exit 198
    }
    if rowsof(`betamat') != 1 | rowsof(`rhomat') != 1 | rowsof(`omegamat') != 1 {
        di as error "_pte_mc_engine: betamat(), rhomat(), and omegamat() must each be single-row matrices"
        di as error "_pte_mc_engine: select a specific industry row before calling the engine"
        exit 198
    }

    // attseed() is part of the MC engine's public contract. The parsed syntax
    // default must reach every downstream ATT consumer, so omitted attseed()
    // remains equivalent to explicitly repeating the same default.
    local _pte_mc_att_seed_opt "seed(`attseed')"
    local _pte_mc_attperiods_opt "attperiods(`attperiods')"

    // Ensure Mata helper functions are available
    // Users must load helpers before calling this program, e.g.:
    //   qui findfile _pte_mc_engine_helpers.mata
    //   qui do "`r(fn)'"
    // Or the calling wrapper (_pte_mc_simulate) handles this.
    // We verify and auto-load if needed using a Stata-level workaround:
    tempname _pte_mc_test_mat
    matrix `_pte_mc_test_mat' = (1, 2, .)
    capture mata: _pte_mc_att_true_avg("`_pte_mc_test_mat'")
    if _rc {
        // Functions not loaded yet - load them now
        qui findfile _pte_mc_engine_helpers.mata
        local _pte_mc_hpath `"`r(fn)'"'
        qui do `"`_pte_mc_hpath'"'
    }
    matrix drop `_pte_mc_test_mat'

    // Set defaults for pfunc
    if "`pfunc'" == "" {
        local pfunc "cd"
    }

    // =========================================================================
    // 1. Initialize result storage
    // =========================================================================
    local L = `attperiods'
    local ncols = `L' + 2    // L+1 period-specific ATTs + 1 overall average

    tempname ATT_est ATT_SE ATT_LB ATT_UB ATT_true ATT_true_draws
    tempvar _pte_mc_treat_firm
    matrix `ATT_est' = J(`nsim', `ncols', .)
    matrix `ATT_SE'  = J(`nsim', `ncols', .)
    matrix `ATT_LB'  = J(`nsim', `ncols', .)
    matrix `ATT_UB'  = J(`nsim', `ncols', .)
    matrix `ATT_true_draws' = J(`nsim', `ncols', .)

    // Track failed iterations
    local nsim_failed = 0

    // --- Method I/II comparison storage (if requested) ---
    if "`compare'" != "" {
        tempname ATT_expost ATT_endog ATT_expost_se ATT_endog_se
        matrix `ATT_expost'    = J(`nsim', 3, .)   // 3 TWFE specs for Method I
        matrix `ATT_endog'     = J(`nsim', 3, .)   // 3 TWFE specs for Method II
        matrix `ATT_expost_se' = J(`nsim', 3, .)   // SE for coverage
        matrix `ATT_endog_se'  = J(`nsim', 3, .)   // SE for coverage
        matrix colnames `ATT_expost'    = spec1 spec2 spec3
        matrix colnames `ATT_endog'     = spec1 spec2 spec3
        matrix colnames `ATT_expost_se' = spec1 spec2 spec3
        matrix colnames `ATT_endog_se'  = spec1 spec2 spec3
        local nsim_compare_failed = 0
    }

    matrix `ATT_true' = J(1, `ncols', .)
    if `order' == 1 {
        // =========================================================================
        // 2. Compute true ATT via analytic formula (order=1 only)
        //    ATT_ell = tau * (1 - rho1^(ell+1)) / (1 - rho1)
        // =========================================================================
        local rho1 = `rhomat'[1, colnumb(`rhomat', "rho1")]

        forvalues ell = 0/`L' {
            local att_ell = `tau' * (1 - `rho1'^(`ell'+1)) / (1 - `rho1')
            matrix `ATT_true'[1, `ell'+1] = `att_ell'
        }

        // Overall average: simple mean of period-specific ATTs
        // (Replaced mata: { } block with compiled Mata function call)
        mata: _pte_mc_att_true_avg("`ATT_true'")
    }

    // Label columns for readability
    local colnames ""
    forvalues ell = 0/`L' {
        local colnames "`colnames' nt`ell'"
    }
    local colnames "`colnames' avg"
    matrix colnames `ATT_true' = `colnames'
    matrix colnames `ATT_est'  = `colnames'
    matrix colnames `ATT_SE'   = `colnames'
    matrix colnames `ATT_LB'   = `colnames'
    matrix colnames `ATT_UB'   = `colnames'

    // Display true ATT contract
    noi di as text ""
    noi di as text _dup(60) "="
    noi di as text "  Monte Carlo Engine: Starting `nsim' simulations"
    noi di as text _dup(60) "="
    noi di as text "  Production function: `pfunc'"
    noi di as text "  Omega poly order:   `order'"
    noi di as text "  ATT periods (L):    `L'"
    noi di as text "  True tau:           `tau'"
    noi di as text "  Bootstrap reps:     `nboot'"
    noi di as text _dup(60) "-"
    if `order' == 1 {
        noi di as text "  True ATT (analytic):"
        noi matrix list `ATT_true', noheader format(%9.6f)
    }
    else {
        noi di as text "  True ATT: aggregated from DGP TT_true draws for order(`order')"
    }
    noi di as text _dup(60) "-"

    // =========================================================================
    // 3. MC outer loop
    // =========================================================================
    forvalues m = 1/`nsim' {

        // Progress report
        if mod(`m', 10) == 0 | `m' == 1 | `m' == `nsim' {
            noi di as text "  MC iteration `m'/`nsim'"
        }

        // DGP seed = seed_base + m
        local dgp_seed = `seed' + `m'

        // Preserve current data before DGP generation
        preserve

        // Generate simulated data
        // Build rhomat1 pass-through option for DGP
        local _pte_mc_rhomat1_opt ""
        if `"`rhomat1'"' != "" {
            local _pte_mc_rhomat1_opt "rhomat1(`rhomat1')"
        }

        cap noisily {
            _pte_mc_dgp, betamat(`betamat') rhomat(`rhomat') ///
                `_pte_mc_rhomat1_opt' ///
                omegamat(`omegamat') ///
                seed(`dgp_seed') tau(`tau') ///
                sigma_eps0(`sigma_eps0') sigma_eps1(`sigma_eps1') ///
                mu_v(`mu_v') sigma_v(`sigma_v') ///
                order(`order') pfunc(`pfunc') ///
                attperiods(`attperiods')
        }
        if _rc != 0 {
            local nsim_failed = `nsim_failed' + 1
            noi di as text "  Warning: MC iteration `m' DGP failed (rc=" _rc ")"
            restore
            continue
        }

        // Store DGP true ATT draws. For nonlinear evolution orders, the
        // DGP-implied TT_true path is the Monte Carlo truth benchmark.
        tempname _pte_mc_att_true_draw
        capture matrix `_pte_mc_att_true_draw' = r(ATT_true)
        if _rc == 0 {
            forvalues j = 1/`ncols' {
                matrix `ATT_true_draws'[`m', `j'] = `_pte_mc_att_true_draw'[1, `j']
            }
            if `m' == 1 {
                cap matrix _pte_mc_ATT_true_dgp = `_pte_mc_att_true_draw'
            }
        }

        // Save simulated dataset if needed for bootstrap
        if `nboot' > 0 {
            tempfile mc_data_`m'
            qui save `mc_data_`m'', replace
        }

        // Skip estimation if noestimate specified (data generation only mode)
        if "`noestimate'" != "" {
            restore
            continue
        }

        // -----------------------------------------------------------------
        // Estimate ATT
        // -----------------------------------------------------------------
        cap noisily {
            qui pte lny, free(`free') proxy(`proxy') state(`state') ///
                control(`control') treatment(`treatment') ///
                pfunc(`pfunc') omegapoly(`order') ///
                `_pte_mc_attperiods_opt' ///
                `_pte_mc_att_seed_opt'

            // Store estimated ATT
            // Current pte releases the full ATT path as a row-vector e(att)
            // with the pooled average in the last column. Keep the legacy
            // e(att_by_period) + scalar fallback for older contracts.
            local _pte_mc_has_att_vec = 0
            cap confirm matrix e(att)
            if _rc == 0 {
                local _pte_mc_has_att_vec = 1
                tempname _pte_mc_att_vec
                matrix `_pte_mc_att_vec' = e(att)
            }

            local _pte_mc_has_period = 0
            if !`_pte_mc_has_att_vec' {
                cap confirm matrix e(att_by_period)
                if _rc == 0 {
                    local _pte_mc_has_period = 1
                    tempname _pte_mc_att_period
                    matrix `_pte_mc_att_period' = e(att_by_period)
                }
            }

            if `_pte_mc_has_att_vec' == 1 {
                local _pte_mc_acols = colsof(`_pte_mc_att_vec')
                local _pte_mc_store_cols = min(`_pte_mc_acols', `ncols')
                forvalues j = 1/`_pte_mc_store_cols' {
                    matrix `ATT_est'[`m', `j'] = `_pte_mc_att_vec'[1, `j']
                }
            }
            else {
                if `_pte_mc_has_period' == 1 {
                    local _pte_mc_pcols = colsof(`_pte_mc_att_period')
                    local _pte_mc_store_cols = min(`_pte_mc_pcols', `L' + 1)
                    forvalues j = 1/`_pte_mc_store_cols' {
                        matrix `ATT_est'[`m', `j'] = `_pte_mc_att_period'[1, `j']
                    }
                }

                cap scalar _pte_mc_att_overall = e(ATT_avg)
                if _rc != 0 {
                    cap scalar _pte_mc_att_overall = e(att)
                }
                if _rc == 0 {
                    matrix `ATT_est'[`m', `ncols'] = _pte_mc_att_overall
                }
            }
        }
        if _rc != 0 {
            local nsim_failed = `nsim_failed' + 1
            noi di as text "  Warning: MC iteration `m' estimation failed (rc=" _rc ")"
            restore
            continue
        }

        // -----------------------------------------------------------------
        // Method I/II comparison via pte_compare (if requested)
        // -----------------------------------------------------------------
        if "`compare'" != "" {
            // Save pte e() state: pte_compare clears e(cmd)="pte" after
            // each call, so subsequent calls would fail the e(cmd)=="pte"
            // prerequisite check. Use estimates store/restore to preserve.
            cap estimates store _pte_mc_iter
            local _pte_mc_has_stored = (_rc == 0)

            // Method I: Ex-post regression
            if `_pte_mc_has_stored' {
                qui estimates restore _pte_mc_iter
            }
            cap noisily {
                qui pte_compare, method(expost)
                matrix `ATT_expost'[`m', 1] = e(att_expost_1)
                matrix `ATT_expost'[`m', 2] = e(att_expost_2)
                matrix `ATT_expost'[`m', 3] = e(att_expost_3)
                matrix `ATT_expost_se'[`m', 1] = e(se_expost_1)
                matrix `ATT_expost_se'[`m', 2] = e(se_expost_2)
                matrix `ATT_expost_se'[`m', 3] = e(se_expost_3)
            }
            if _rc != 0 {
                local nsim_compare_failed = `nsim_compare_failed' + 1
            }

            // Method II: Endogenous productivity
            if `_pte_mc_has_stored' {
                qui estimates restore _pte_mc_iter
            }
            cap noisily {
                qui pte_compare, method(endog) omegapoly(`order')
                matrix `ATT_endog'[`m', 1] = e(att_endog_1)
                matrix `ATT_endog'[`m', 2] = e(att_endog_2)
                matrix `ATT_endog'[`m', 3] = e(att_endog_3)
                matrix `ATT_endog_se'[`m', 1] = e(se_endog_1)
                matrix `ATT_endog_se'[`m', 2] = e(se_endog_2)
                matrix `ATT_endog_se'[`m', 3] = e(se_endog_3)
            }
            if _rc != 0 {
                local nsim_compare_failed = `nsim_compare_failed' + 1
            }

            // Clean up stored estimates
            cap estimates drop _pte_mc_iter
        }

        // -----------------------------------------------------------------
        // Bootstrap inner loop
        // -----------------------------------------------------------------
        if `nboot' > 0 {
            tempname _pte_mc_ATT_boot
            matrix `_pte_mc_ATT_boot' = J(`nboot', `ncols', .)

            forvalues b = 1/`nboot' {
                cap noisily {
                    // Mirror the official DO/bootstrap helper outer-seed law:
                    // each bootstrap draw is indexed by b, not by a single
                    // ambient RNG stream initialized once per MC iteration.
                    local _pte_mc_boot_outer_seed = `bootseed' + `b' - 1
                    set seed `_pte_mc_boot_outer_seed'

                    // Reload the MC sample
                    qui use `mc_data_`m'', clear

                    // Bootstrap law must mirror the official DO and the live
                    // package bootstrap helpers: stratify by firm-level ever-treated.
                    capture drop `_pte_mc_treat_firm'
                    quietly bysort firm: egen `_pte_mc_treat_firm' = max(`treatment')
                    qui bsample, strata(`_pte_mc_treat_firm') cluster(firm) idcluster(firm1)
                    qui replace firm = firm1
                    qui drop firm1
                    qui xtset firm year

                    // Re-estimate
                    qui pte lny, free(`free') proxy(`proxy') state(`state') ///
                        control(`control') treatment(`treatment') ///
                        pfunc(`pfunc') omegapoly(`order') ///
                        `_pte_mc_attperiods_opt' ///
                        `_pte_mc_att_seed_opt'

                    // Store bootstrap ATT estimates
                    local _pte_mc_b_has_att_vec = 0
                    cap confirm matrix e(att)
                    if _rc == 0 {
                        local _pte_mc_b_has_att_vec = 1
                        tempname _pte_mc_b_att_vec
                        matrix `_pte_mc_b_att_vec' = e(att)
                    }

                    local _pte_mc_b_has_period = 0
                    if !`_pte_mc_b_has_att_vec' {
                        cap confirm matrix e(att_by_period)
                        if _rc == 0 {
                            local _pte_mc_b_has_period = 1
                            tempname _pte_mc_b_att_period
                            matrix `_pte_mc_b_att_period' = e(att_by_period)
                        }
                    }

                    if `_pte_mc_b_has_att_vec' == 1 {
                        local _pte_mc_b_acols = colsof(`_pte_mc_b_att_vec')
                        local _pte_mc_b_store = min(`_pte_mc_b_acols', `ncols')
                        forvalues j = 1/`_pte_mc_b_store' {
                            matrix `_pte_mc_ATT_boot'[`b', `j'] = ///
                                `_pte_mc_b_att_vec'[1, `j']
                        }
                    }
                    else {
                        if `_pte_mc_b_has_period' == 1 {
                            local _pte_mc_b_pcols = colsof(`_pte_mc_b_att_period')
                            local _pte_mc_b_store = min(`_pte_mc_b_pcols', `L' + 1)
                            forvalues j = 1/`_pte_mc_b_store' {
                                matrix `_pte_mc_ATT_boot'[`b', `j'] = ///
                                    `_pte_mc_b_att_period'[1, `j']
                            }
                        }

                        cap scalar _pte_mc_b_att_ov = e(ATT_avg)
                        if _rc != 0 {
                            cap scalar _pte_mc_b_att_ov = e(att)
                        }
                        if _rc == 0 {
                            matrix `_pte_mc_ATT_boot'[`b', `ncols'] = _pte_mc_b_att_ov
                        }
                    }
                }
                // Silently skip failed bootstrap iterations
            }

            // Compute SE from bootstrap distribution
            // (Replaced mata: { } block with compiled Mata function call)
            tempname _pte_mc_se_row _pte_mc_lb_row _pte_mc_ub_row
            mata: _pte_mc_boot_se_ci("`_pte_mc_ATT_boot'", "`_pte_mc_se_row'", "`_pte_mc_lb_row'", "`_pte_mc_ub_row'")

            // Store SE and CI for this MC iteration
            forvalues j = 1/`ncols' {
                matrix `ATT_SE'[`m', `j'] = `_pte_mc_se_row'[1, `j']
                matrix `ATT_LB'[`m', `j'] = `_pte_mc_lb_row'[1, `j']
                matrix `ATT_UB'[`m', `j'] = `_pte_mc_ub_row'[1, `j']
            }
        }
        // End bootstrap block

        // Restore original data for next MC iteration
        restore

    }
    // End MC outer loop

    // =========================================================================
    // 4. Evaluate results
    // =========================================================================

    // Unconditionally re-load Mata helpers before evaluation.
    // mata which does NOT find functions loaded via do (only .mlib),
    // so we always reload. Each function has capture mata: mata drop
    // at the top, making re-definition safe.
    qui findfile _pte_mc_engine_helpers.mata
    local _pte_mc_hpath2 `"`r(fn)'"'
    qui do `"`_pte_mc_hpath2'"'

    if `order' >= 2 {
        forvalues j = 1/`ncols' {
            mata: st_numscalar("r(_pte_mc_true_mean)", mean(select(st_matrix("`ATT_true_draws'")[., `j'], st_matrix("`ATT_true_draws'")[., `j'] :!= .)))
            if r(_pte_mc_true_mean) < . {
                matrix `ATT_true'[1, `j'] = r(_pte_mc_true_mean)
            }
        }
    }

    // --- 4a. Compute bias ---
    // (Replaced mata: { } block with compiled Mata function call)
    tempname BIAS
    matrix `BIAS' = J(1, `ncols', .)
    mata: _pte_mc_compute_bias("`ATT_est'", "`ATT_true'", "`BIAS'")
    matrix colnames `BIAS' = `colnames'

    // --- 4b. Compute RMSE ---
    // (Replaced mata: { } block with compiled Mata function call)
    tempname RMSE
    matrix `RMSE' = J(1, `ncols', .)
    mata: _pte_mc_compute_rmse("`ATT_est'", "`ATT_true'", "`RMSE'")
    matrix colnames `RMSE' = `colnames'

    // --- 4c. Compute coverage ---
    // (Replaced mata: { } block with compiled Mata function call)
    tempname COVERAGE
    matrix `COVERAGE' = J(1, `ncols', .)
    if `nboot' > 0 {
        mata: _pte_mc_compute_coverage("`ATT_true'", "`ATT_LB'", "`ATT_UB'", "`COVERAGE'")
    }
    matrix colnames `COVERAGE' = `colnames'

    // --- 4d. Compute SE ratio ---
    // (Replaced mata: { } block with compiled Mata function call)
    tempname SE_RATIO
    matrix `SE_RATIO' = J(1, `ncols', .)
    if `nboot' > 0 {
        mata: _pte_mc_compute_se_ratio("`ATT_est'", "`ATT_SE'", "`SE_RATIO'")
    }
    matrix colnames `SE_RATIO' = `colnames'

    // --- 4e. Compute bias/rmse/coverage for Method I/II (if compare) ---
    if "`compare'" != "" {
        // Reference true ATT: use the "avg" column (last column of ATT_true)
        local _pte_mc_true_avg = `ATT_true'[1, `ncols']

        tempname BIAS_expost BIAS_endog RMSE_expost RMSE_endog
        tempname COVERAGE_expost COVERAGE_endog
        matrix `BIAS_expost'     = J(1, 3, .)
        matrix `BIAS_endog'      = J(1, 3, .)
        matrix `RMSE_expost'     = J(1, 3, .)
        matrix `RMSE_endog'      = J(1, 3, .)
        matrix `COVERAGE_expost' = J(1, 3, .)
        matrix `COVERAGE_endog'  = J(1, 3, .)

        forvalues s = 1/3 {
            // --- Method I (expost) ---
            local _sum_ex = 0
            local _sumsq_ex = 0
            local _nvalid_ex = 0
            local _ncover_ex = 0
            forvalues i = 1/`nsim' {
                if `ATT_expost'[`i', `s'] != . {
                    local _est_ex = `ATT_expost'[`i', `s']
                    local _sum_ex = `_sum_ex' + `_est_ex'
                    local _sumsq_ex = `_sumsq_ex' + (`_est_ex' - `_pte_mc_true_avg')^2
                    local _nvalid_ex = `_nvalid_ex' + 1
                    if `ATT_expost_se'[`i', `s'] != . {
                        local _ci_lo = `_est_ex' - 1.96 * `ATT_expost_se'[`i', `s']
                        local _ci_hi = `_est_ex' + 1.96 * `ATT_expost_se'[`i', `s']
                        if `_pte_mc_true_avg' >= `_ci_lo' & `_pte_mc_true_avg' <= `_ci_hi' {
                            local _ncover_ex = `_ncover_ex' + 1
                        }
                    }
                }
            }
            if `_nvalid_ex' > 0 {
                matrix `BIAS_expost'[1, `s'] = `_sum_ex'/`_nvalid_ex' - `_pte_mc_true_avg'
                matrix `RMSE_expost'[1, `s'] = sqrt(`_sumsq_ex'/`_nvalid_ex')
                matrix `COVERAGE_expost'[1, `s'] = `_ncover_ex'/`_nvalid_ex'
            }

            // --- Method II (endog) ---
            local _sum_en = 0
            local _sumsq_en = 0
            local _nvalid_en = 0
            local _ncover_en = 0
            forvalues i = 1/`nsim' {
                if `ATT_endog'[`i', `s'] != . {
                    local _est_en = `ATT_endog'[`i', `s']
                    local _sum_en = `_sum_en' + `_est_en'
                    local _sumsq_en = `_sumsq_en' + (`_est_en' - `_pte_mc_true_avg')^2
                    local _nvalid_en = `_nvalid_en' + 1
                    if `ATT_endog_se'[`i', `s'] != . {
                        local _ci_lo = `_est_en' - 1.96 * `ATT_endog_se'[`i', `s']
                        local _ci_hi = `_est_en' + 1.96 * `ATT_endog_se'[`i', `s']
                        if `_pte_mc_true_avg' >= `_ci_lo' & `_pte_mc_true_avg' <= `_ci_hi' {
                            local _ncover_en = `_ncover_en' + 1
                        }
                    }
                }
            }
            if `_nvalid_en' > 0 {
                matrix `BIAS_endog'[1, `s'] = `_sum_en'/`_nvalid_en' - `_pte_mc_true_avg'
                matrix `RMSE_endog'[1, `s'] = sqrt(`_sumsq_en'/`_nvalid_en')
                matrix `COVERAGE_endog'[1, `s'] = `_ncover_en'/`_nvalid_en'
            }
        }
        matrix colnames `BIAS_expost'     = spec1 spec2 spec3
        matrix colnames `BIAS_endog'      = spec1 spec2 spec3
        matrix colnames `RMSE_expost'     = spec1 spec2 spec3
        matrix colnames `RMSE_endog'      = spec1 spec2 spec3
        matrix colnames `COVERAGE_expost' = spec1 spec2 spec3
        matrix colnames `COVERAGE_endog'  = spec1 spec2 spec3
    }

    // =========================================================================
    // 5. Final report
    // =========================================================================
    if "`noestimate'" == "" {
        noi di as text ""
        noi di as text _dup(60) "="
        noi di as text "  Monte Carlo Simulation Results"
        noi di as text _dup(60) "="
        noi di as text "  Simulations:  `nsim'"
        noi di as text "  Succeeded:    " `nsim' - `nsim_failed'
        noi di as text "  Failed:       `nsim_failed'"
        noi di as text "  Bootstrap:    `nboot'"
        noi di as text "  True tau:     " %9.6f `tau'
        noi di as text _dup(60) "-"

        // Display ATT comparison table
        // (Replaced mata: { } block with compiled Mata function call)
        noi di as text ""
        noi di as text "  Period    True ATT    Mean Est    Bias        RMSE"
        noi di as text _dup(60) "-"
        mata: _pte_mc_display_att_table("`ATT_true'", "`ATT_est'", "`BIAS'", "`RMSE'")

        // Display bootstrap results if available
        if `nboot' > 0 {
            noi di as text ""
            noi di as text _dup(60) "-"
            noi di as text "  Bootstrap Inference Summary"
            noi di as text _dup(60) "-"
            noi di as text "  Period    Coverage    SE Ratio"
            noi di as text _dup(60) "-"
            // (Replaced mata: { } block with compiled Mata function call)
            mata: _pte_mc_display_boot_table("`COVERAGE'", "`SE_RATIO'")
        }

        // --- Method I/II comparison results (if compare) ---
        if "`compare'" != "" {
            noi di as text ""
            noi di as text _dup(60) "-"
            noi di as text "  Method I/II Comparison Summary (vs CLK true ATT)"
            noi di as text _dup(60) "-"
            noi di as text "  Compare iterations failed: `nsim_compare_failed'"
            noi di as text "  True ATT (avg):  " %9.6f `_pte_mc_true_avg'
            noi di as text ""
            noi di as text "  Method I (Ex-post TWFE):"
            noi di as text "  Spec      Bias        RMSE        Coverage"
            noi di as text _dup(60) "-"
            forvalues s = 1/3 {
                noi di as text "  Spec `s'" ///
                    _col(12) %9.6f `BIAS_expost'[1, `s'] ///
                    _col(24) %9.6f `RMSE_expost'[1, `s'] ///
                    _col(36) %9.4f `COVERAGE_expost'[1, `s']
            }
            noi di as text ""
            noi di as text "  Method II (Endogenous TWFE):"
            noi di as text "  Spec      Bias        RMSE        Coverage"
            noi di as text _dup(60) "-"
            forvalues s = 1/3 {
                noi di as text "  Spec `s'" ///
                    _col(12) %9.6f `BIAS_endog'[1, `s'] ///
                    _col(24) %9.6f `RMSE_endog'[1, `s'] ///
                    _col(36) %9.4f `COVERAGE_endog'[1, `s']
            }
        }

        noi di as text _dup(60) "="
    }
    else {
        // noestimate mode: just report completion
        noi di as text ""
        noi di as text _dup(60) "="
        noi di as text "  MC Data Generation Complete (noestimate mode)"
        noi di as text "  Simulations:  `nsim'"
        noi di as text "  Failed:       `nsim_failed'"
        noi di as text _dup(60) "="
    }

    // =========================================================================
    // 5.5 Save MC results to file if saving() specified
    // =========================================================================
    if "`saving'" != "" {
        // Preserve current data
        preserve
        clear

        // Create dataset from MC result matrices
        qui set obs `nsim'
        qui gen int sim_id = _n

        // Add ATT estimates for each period
        forvalues j = 1/`ncols' {
            local vname : word `j' of `colnames'
            qui gen double ATT_`vname' = .
            forvalues i = 1/`nsim' {
                qui replace ATT_`vname' = `ATT_est'[`i', `j'] in `i'
            }
        }

        // Add SE if bootstrap was performed
        if `nboot' > 0 {
            forvalues j = 1/`ncols' {
                local vname : word `j' of `colnames'
                qui gen double SE_`vname' = .
                forvalues i = 1/`nsim' {
                    qui replace SE_`vname' = `ATT_SE'[`i', `j'] in `i'
                }
            }
        }

        // Save to file
        qui save "`saving'", replace
        noi di as text "  MC results saved to: `saving'"

        // Restore original data
        restore
    }

    // =========================================================================
    // 6. Return results
    // =========================================================================
    return matrix ATT_true = `ATT_true'
    return matrix ATT_est  = `ATT_est'
    return matrix BIAS     = `BIAS'
    return matrix RMSE     = `RMSE'

    // Always return SE/CI matrices (may be all missing if nboot==0)
    return matrix ATT_SE   = `ATT_SE'
    return matrix ATT_LB   = `ATT_LB'
    return matrix ATT_UB   = `ATT_UB'
    return matrix COVERAGE = `COVERAGE'
    return matrix SE_RATIO = `SE_RATIO'

    // --- Method I/II comparison return values ---
    if "`compare'" != "" {
        return matrix ATT_expost      = `ATT_expost'
        return matrix ATT_endog       = `ATT_endog'
        return matrix ATT_expost_se   = `ATT_expost_se'
        return matrix ATT_endog_se    = `ATT_endog_se'
        return matrix BIAS_expost     = `BIAS_expost'
        return matrix BIAS_endog      = `BIAS_endog'
        return matrix RMSE_expost     = `RMSE_expost'
        return matrix RMSE_endog      = `RMSE_endog'
        return matrix COVERAGE_expost = `COVERAGE_expost'
        return matrix COVERAGE_endog  = `COVERAGE_endog'
    }

    return scalar nsim        = `nsim'
    return scalar nsim_failed = `nsim_failed'
    return scalar nboot       = `nboot'
    return scalar tau         = `tau'
    return scalar seed        = `seed'
    return scalar attperiods  = `L'

end
