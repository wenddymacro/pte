*! _pte_bygroup.ado

version 14.0
// Bygroup loop estimation: parse groups, initialize matrices, loop over groups
// calling/002/003 modules, pool ATT via append+tabstat, bootstrap inference

capture program drop _pte_bg_clear
program define _pte_bg_clear, eclass
    version 14.0
    tempname b V
    matrix `b' = (0)
    matrix colnames `b' = _pte_clear
    matrix `V' = (1)
    matrix colnames `V' = _pte_clear
    matrix rownames `V' = _pte_clear
    capture ereturn post `b' `V'
    capture ereturn local cmd "."
    capture ereturn local by "."
    capture ereturn local groups "."
    capture ereturn scalar n_groups = .
    capture ereturn scalar ngroups = .
end

program define _pte_bygroup, eclass sortpreserve
    version 14.0

    // Preserve the raw option surface so grouped point estimation can
    // distinguish omitted defaults from explicit compatibility aliases.
    local _pte_cmdline `"`0'"'
    local _pte_has_seed = regexm(lower(`"`_pte_cmdline'"'), "(^|[ ,])seed[(]")
    local _pte_has_poly = regexm(lower(`"`_pte_cmdline'"'), "(^|[ ,])poly[(]")
    local _pte_has_omegapoly = regexm(lower(`"`_pte_cmdline'"'), "(^|[ ,])omegapoly[(]")
    
    // =========================================================================
    // 1. Syntax parsing
    // =========================================================================
    capture noisily syntax varlist(min=1 max=1) [if] [in], ///
        BY(varname)                         /// grouping variable
        Free(varlist)                       /// free input variables
        State(varlist)                      /// state variables
        Proxy(varname)                      /// proxy variable
        Treatment(varname)                  /// treatment variable
        [                                   ///
        CONTrol(varlist)                    /// control variables
        PFunc(string)                       /// production function type
        POLY(integer 3)                     /// legacy alias for omegapoly()
        OMEGApoly(integer 3)                /// evolution polynomial order
        eps0window(integer 0)               /// eps0 window passed to _pte_omega
        NSIM(integer -1)                    /// number of counterfactual paths
        ATTperiods(integer 4)               /// max ATT periods
        BOOTstrap(integer 0)                /// bootstrap replications
        SEED(integer 123456)                /// random seed
        SEED_boot(integer -1)               /// bootstrap seed (-1 = use seed)
        REPlicate                           /// replication mode (seed inside industry loop)
        NOATT                               /// skip ATT stage; keep grouped PF/evolution payload
        MIN_obs(integer 100)                /// minimum obs warning threshold
        NOTRIMeps                           /// disable eps0 winsorize
        NOLog                               /// suppress progress display
        NODIAGnose                          /// skip non-required diagnostics
        ]
    local _pte_syntax_rc = _rc
    if `_pte_syntax_rc' != 0 {
        _pte_bg_clear
        exit `_pte_syntax_rc'
    }
    
    // Dependent variable
    local depvar `varlist'

    // Grouped helpers publish a full eclass contract. Clear any prior result
    // now that parsing succeeded so validation failures cannot masquerade as
    // a fresh grouped run.
    _pte_bg_clear
    
    // Default production function type
    if "`pfunc'" == "" local pfunc "translog"

    // Keep grouped helpers on the same poly()/omegapoly() alias contract as
    // the public wrapper and _pte_prodfunc. If poly() is omitted, do not let
    // the syntax default synthesize a false conflict against explicit
    // omegapoly().
    if `_pte_has_poly' {
        if `poly' < 1 | `poly' > 4 {
            capture ereturn clear
            display as error "_pte_bygroup: poly() must be between 1 and 4"
            exit 198
        }
        if `_pte_has_omegapoly' & `omegapoly' != `poly' {
            capture ereturn clear
            display as error "_pte_bygroup: cannot specify both poly(`poly') and omegapoly(`omegapoly')"
            exit 198
        }
        local omegapoly = `poly'
    }
    local poly = `omegapoly'

    // Forward production-function controls (paper Eq. (15) beta_t / DOs industry controls)
    // Keep empty when user did not specify control() to avoid invalid option syntax.
    local _pf_control_opt ""
    if "`control'" != "" {
        local _pf_control_opt "control(`control')"
    }
    local _pf_group_stage_opt "industry(`by') byindustry"
    local _diag_opt ""
    if "`nodiagnose'" != "" {
        local _diag_opt "nodiagnose"
    }
    
    // Bootstrap seed defaults to main seed
    if `seed_boot' == -1 local seed_boot = `seed'
    
    local do_att = ("`noatt'" == "")

    // Official industry point DOs reset the grouped ATT simulation to 10000.
    // Mirror that contract only for grouped point estimation when callers did
    // not explicitly request seed(). Grouped bootstrap keeps its existing
    // seed flow, and explicit seed() always wins.
    if `do_att' & `bootstrap' == 0 & !`_pte_has_seed' {
        local seed = 10000
    }
    
    // =========================================================================
    // 2. Input validation
    // =========================================================================
    
    // Validate pfunc
    if "`pfunc'" != "cd" & "`pfunc'" != "translog" {
        capture ereturn clear
        display as error "_pte_bygroup: pfunc must be cd or translog"
        exit 198
    }
    
    // Validate omegapoly range (1-4)
    if `omegapoly' < 1 | `omegapoly' > 4 {
        capture ereturn clear
        display as error "_pte_bygroup: omegapoly must be 1, 2, 3, or 4"
        exit 198
    }
    
    // Validate attperiods range (non-negative)
    if `attperiods' < 0 {
        capture ereturn clear
        display as error "_pte_bygroup: attperiods must be non-negative"
        exit 198
    }
    
    // Match the serial/bootstrap public omission contract: order 1 uses one
    // path, while higher-order evolution laws default to 100 paths.
    if `nsim' == -1 {
        if `omegapoly' == 1 {
            local nsim = 1
        }
        else {
            local nsim = 100
        }
    }

    // Match the public pte contract: nsim is a positive ATT-path count with
    // no grouped-only upper cap. noatt runs skip ATT entirely, but the
    // grouped helper should still mirror the main-command contract rather
    // than rejecting large positive nsim() values that the public wrapper
    // accepts on the serial path.
    if `nsim' < 1 {
        capture ereturn clear
        display as error "_pte_bygroup: nsim must be >= 1"
        exit 198
    }

    local _bg_eps0_legacy_opt ""
    local _bg_att_legacy_opt ""
    if `eps0window' == 0 {
        local _bg_eps0_legacy_opt "legacypooledeps0"
        local _bg_att_legacy_opt "legacyattgaussian"
    }
    
    // Validate bootstrap range
    if `bootstrap' < 0 {
        capture ereturn clear
        display as error "_pte_bygroup: bootstrap must be non-negative"
        exit 198
    }
    if !`do_att' & `bootstrap' > 0 {
        capture ereturn clear
        display as error "_pte_bygroup: noatt cannot be combined with bootstrap()"
        exit 198
    }
    
    // Validate by variable exists
    capture confirm variable `by'
    if _rc != 0 {
        capture ereturn clear
        display as error "_pte_bygroup: variable `by' not found"
        exit 111
    }
    
    // Validate panel structure (xtset required)
    capture _xt, trequired
    if _rc != 0 {
        capture ereturn clear
        display as error "_pte_bygroup: data must be xtset as panel"
        exit 459
    }
    local idvar = r(ivar)
    local timevar = r(tvar)

    local _pte_n_controls : word count `control'
    
    // =========================================================================
    // 3. Step 1: Group variable parsing and initialization (Task-1)
    // =========================================================================
    
    // Mark estimation sample
    marksample touse
    
    // ─────────────────────────────────────────────────────────────────────
    // 3.1 Detect variable type (numeric vs string) [Task-1.2]
    // ─────────────────────────────────────────────────────────────────────
    local _pte_byvar_type ""
    capture confirm numeric variable `by'
    if _rc == 0 {
        local _pte_byvar_type "numeric"
    }
    else {
        capture confirm string variable `by'
        if _rc == 0 {
            local _pte_byvar_type "string"
        }
        else {
            capture ereturn clear
            display as error "_pte_bygroup: `by' is neither numeric nor string"
            exit 111
        }
    }
    
    // ─────────────────────────────────────────────────────────────────────
    // 3.2 Get group list via levelsof [Task-1.1]
    // ─────────────────────────────────────────────────────────────────────
    if "`_pte_byvar_type'" == "numeric" {
        qui levelsof `by' if `touse', local(groups)
    }
    else {
        // Keep compound quotes so embedded spaces remain one group token.
        qui levelsof `by' if `touse', local(groups)
    }
    
    // Count groups using r(r) from levelsof (robust for strings with spaces)
    local n_groups = r(r)
    
    // Validate at least one group
    if `n_groups' == 0 {
        capture ereturn clear
        display as error "_pte_bygroup: no groups found in variable `by'"
        exit 2000
    }
    
    // Display header
    if "`nolog'" == "" {
        display as text ""
        display as text "{hline 70}"
        display as text "PTE Bygroup Estimation"
        display as text "{hline 70}"
        display as text "  Grouping variable:  `by' (`_pte_byvar_type')"
        display as text "  Number of groups:   `n_groups'"
        display as text "  Production function: `pfunc'"
        display as text "  Evolution order:    `omegapoly'"
        if `do_att' {
            display as text "  ATT periods:        `attperiods'"
            display as text "  Counterfactual paths: `nsim'"
        }
        else {
            display as text "  ATT estimation:     Skipped (noatt)"
        }
        if `bootstrap' > 0 {
            display as text "  Bootstrap reps:     `bootstrap'"
        }
        display as text "{hline 70}"
    }
    
    // ─────────────────────────────────────────────────────────────────────
    // 3.3 Determine parameter dimensions [Task-1.3]
    // ─────────────────────────────────────────────────────────────────────
    if "`pfunc'" == "cd" {
        local n_beta_struct = 2
    }
    else {
        local n_beta_struct = 5
    }
    local n_beta = `n_beta_struct' + 1
    local beta_colnames "beta_l beta_k beta_t"
    if "`pfunc'" != "cd" {
        local beta_colnames "beta_l beta_k beta_l2 beta_k2 beta_lk beta_t"
    }
    if `_pte_n_controls' > 1 {
        local n_beta = `n_beta_struct' + `_pte_n_controls'
        local beta_colnames "beta_l beta_k"
        if "`pfunc'" != "cd" {
            local beta_colnames "beta_l beta_k beta_l2 beta_k2 beta_lk"
        }
        local beta_colnames "`beta_colnames' `control'"
    }
    
    // n_rho: constant + polynomial coefficients (rho_0, rho_1, ..., rho_P)
    local n_rho = `omegapoly' + 1
    
    // n_att: ATT_0, ATT_1, ..., ATT_L, ATT_avg
    local n_att = `attperiods' + 2
    
    // ─────────────────────────────────────────────────────────────────────
    // 3.4 Initialize result matrices [Task-1.3, Task-1.4]
    // ─────────────────────────────────────────────────────────────────────
    // All matrices initialized to missing (.) with G rows
    tempname BETA RHO SIGMA N_OBS N_FIRMS
    
    matrix `BETA'   = J(`n_groups', `n_beta', .)
    matrix `RHO'    = J(`n_groups', `n_rho', .)
    matrix `SIGMA'  = J(`n_groups', 1, .)
    matrix `N_OBS'  = J(`n_groups', 1, .)
    matrix `N_FIRMS' = J(`n_groups', 1, .)
    if `do_att' {
        tempname ATT
        matrix `ATT' = J(`n_groups', `n_att', .)
    }
    
    // ─────────────────────────────────────────────────────────────────────
    // 3.5 Set matrix row names (group labels) and column names
    // ─────────────────────────────────────────────────────────────────────
    // Row names: sequential group indices (1, 2, ..., G)
    // Avoids issues with string group values containing spaces
    local rownames ""
    forvalues i = 1/`n_groups' {
        local rownames "`rownames' grp_`i'"
    }
    matrix rownames `BETA'   = `rownames'
    matrix rownames `RHO'    = `rownames'
    matrix rownames `SIGMA'  = `rownames'
    matrix rownames `N_OBS'  = `rownames'
    matrix rownames `N_FIRMS' = `rownames'
    if `do_att' {
        matrix rownames `ATT' = `rownames'
    }
    
    // Column names for BETA
    matrix colnames `BETA' = `beta_colnames'
    
    // Column names for RHO: rho_0, rho_1, ..., rho_P
    local rho_colnames ""
    forvalues j = 0/`omegapoly' {
        local rho_colnames "`rho_colnames' rho_`j'"
    }
    matrix colnames `RHO' = `rho_colnames'
    
    // Column names for SIGMA
    matrix colnames `SIGMA' = sigma_eps
    
    // Column names for ATT: ATT_0, ATT_1, ..., ATT_L, ATT_avg
    local att_colnames ""
    forvalues l = 0/`attperiods' {
        local att_colnames "`att_colnames' ATT_`l'"
    }
    local att_colnames "`att_colnames' ATT_avg"
    if `do_att' {
        matrix colnames `ATT' = `att_colnames'
    }
    
    // Column names for N matrices
    matrix colnames `N_OBS'  = N_obs
    matrix colnames `N_FIRMS' = N_firms
    
    // ─────────────────────────────────────────────────────────────────────
    // 3.6 Create tempfile base path [Task-1.5]
    // ─────────────────────────────────────────────────────────────────────
    tempfile _pte_tmpbase
    // Derive base path by stripping extension for constructing tt_g.dta paths
    local tempdir_base "`_pte_tmpbase'"
    local internal_saved_groups ""
    local internal_first_group ""
    local tt_saved_groups ""
    local tt_first_group ""
    
    // =========================================================================
    // 4. Step 2: Group loop estimation (Task-2 ~ Task-6)
    // =========================================================================
    
    // ─────────────────────────────────────────────────────────────────────
    // 4.1 Group counter initialization [Task-2.1]
    // ─────────────────────────────────────────────────────────────────────
    local g = 0
    local n_success_groups = 0
    local first_fail_rc = 0
    
    // ─────────────────────────────────────────────────────────────────────
    // 4.2 Main group loop [Task-2.2]
    // ─────────────────────────────────────────────────────────────────────
    foreach grp of local groups {
        
        // 4.3 Increment group counter [Task-2.3]
        local ++g
        
        // 4.4 Progress display [Task-2.4]
        if "`nolog'" == "" {
            display as text ""
            display as text "{hline 60}"
            display as text "Estimating group `g' of `n_groups': `by' = `grp'"
            display as text "{hline 60}"
        }
        
        // 4.5 Preserve data before subsetting [Task-2.5]
        preserve
        
        // 4.6 Filter data to current group [Task-2.6]
        if "`_pte_byvar_type'" == "numeric" {
            qui keep if `by' == `grp' & `touse'
        }
        else {
            // String variables require quotes around the value
            qui keep if `by' == "`grp'" & `touse'
        }
        
        // 4.7 Record sample size [Task-2.7]
        qui count
        matrix `N_OBS'[`g', 1] = r(N)
        
        // Count unique firms using egen tag (Stata 14 compatible fallback)
        tempvar _tag
        qui egen `_tag' = tag(`idvar')
        qui count if `_tag' == 1
        matrix `N_FIRMS'[`g', 1] = r(N)
        
        // Minimum sample size warning
        if `N_OBS'[`g', 1] < `min_obs' & "`nodiagnose'" == "" {
            display as text ///
                "Warning: Group `grp' has only " `N_OBS'[`g', 1] ///
                " observations (< `min_obs')"
        }
        
        // 4.8 Error-captured estimation block [Task-2.8]
        capture noisily {
            
            // Stage 1: Production function estimation [Task-3]
            _pte_prodfunc, treatment(`treatment') id(`idvar') time(`timevar') ///
                lny(`depvar') free(`free') state(`state') ///
                proxy(`proxy') pfunc(`pfunc') poly(`poly') ///
                omegapoly(`omegapoly') dopooledz `_pf_group_stage_opt' ///
                `_pf_control_opt' `_diag_opt' noreport replace

            capture drop _pte_pf_esample
            quietly gen byte _pte_pf_esample = e(sample)
            
            // Store grouped production-function coefficients. The legacy
            // grouped contract keeps beta_t for single-control paths, while
            // multi-control runs append the exact stage-1 control names.
            tempname _beta_g _beta_ctrl_g
            matrix `_beta_g' = e(b)
            local _ncol_beta = colsof(`_beta_g')
            if `_ncol_beta' != `n_beta_struct' {
                display as error ///
                    "production function estimation returned `_ncol_beta' structural params, expected `n_beta_struct'"
                error 503
            }
            forvalues j = 1/`n_beta_struct' {
                matrix `BETA'[`g', `j'] = `_beta_g'[1, `j']
            }
            capture matrix `_beta_ctrl_g' = e(beta_controls)
            if _rc != 0 | colsof(`_beta_ctrl_g') < 1 {
                display as error ///
                    "production function estimation did not publish the stage-1 beta_controls matrix needed for beta_t"
                error 503
            }
            if `_pte_n_controls' > 1 {
                local _beta_ctrl_names : colnames `_beta_ctrl_g'
                foreach _ctrl of local control {
                    local _ctrl_pos : list posof "`_ctrl'" in _beta_ctrl_names
                    if `_ctrl_pos' < 1 {
                        display as error ///
                            "production function estimation did not publish grouped control coefficient for `_ctrl'"
                        error 503
                    }
                    local _ctrl_j = `: list posof "`_ctrl'" in control'
                    matrix `BETA'[`g', `n_beta_struct' + `_ctrl_j'] = ///
                        `_beta_ctrl_g'[1, `_ctrl_pos']
                }
            }
            else {
                if "`control'" != "" {
                    local _only_ctrl : word 1 of `control'
                    local _beta_ctrl_names : colnames `_beta_ctrl_g'
                    local _ctrl_pos : list posof "`_only_ctrl'" in _beta_ctrl_names
                    if `_ctrl_pos' < 1 {
                        display as error ///
                            "production function estimation did not publish grouped control coefficient for `_only_ctrl'"
                        error 503
                    }
                    matrix `BETA'[`g', `n_beta'] = `_beta_ctrl_g'[1, `_ctrl_pos']
                }
                else {
                    matrix `BETA'[`g', `n_beta'] = `_beta_ctrl_g'[1, 1]
                }
            }
            
            // Verify stage-1/transition outputs follow the live producer
            // contract. _pte_prodfunc carries the canonical _pte_mid helper
            // forward and may drop the legacy mid alias before grouped
            // consumers run.
            confirm variable phi
            capture confirm variable _pte_mid
            if _rc != 0 {
                confirm variable mid
            }
            
            // Stage 2: Evolution parameters + eps0 distribution [Task-4]
            _pte_omega, treatment(`treatment') omegapoly(`omegapoly') ///
                eps0window(`eps0window') ///
                `_bg_eps0_legacy_opt' `notrimeps' `_diag_opt'

            if "`_bg_eps0_legacy_opt'" != "" & "`notrimeps'" == "" {
                tempvar _bg_eps0_trim_work
                quietly summarize _pte_eps0 if _pte_eps0_ind == 1
                local _bg_sigma_eps = r(sd)
                local _bg_N_eps0 = r(N)
                quietly gen double `_bg_eps0_trim_work' = _pte_eps0 if _pte_eps0_ind == 1
                capture which winsor2
                if _rc == 0 {
                    quietly winsor2 `_bg_eps0_trim_work', replace cuts(1 99) trim
                }
                else {
                    quietly _pctile `_bg_eps0_trim_work', p(1 99)
                    local _bg_p1 = r(r1)
                    local _bg_p99 = r(r2)
                    quietly replace `_bg_eps0_trim_work' = . if ///
                        `_bg_eps0_trim_work' < `_bg_p1' | ///
                        `_bg_eps0_trim_work' > `_bg_p99'
                }
                quietly summarize `_bg_eps0_trim_work'
                local _bg_sigma_eps_trim = r(sd)
                local _bg_N_eps0_trim = r(N)
                ereturn scalar sigma_eps = `_bg_sigma_eps'
                ereturn scalar sigma_eps_trim = `_bg_sigma_eps_trim'
                ereturn scalar N_eps0 = `_bg_N_eps0'
                ereturn scalar N_eps0_trim = `_bg_N_eps0_trim'
            }
            
            // Interface verification [Task-4.3]
            tempname _rho_g
            matrix `_rho_g' = e(rho_0)
            local _ncol_rho = colsof(`_rho_g')
            if `_ncol_rho' != `n_rho' {
                display as error ///
                    "omega recovery returned `_ncol_rho' rho params, expected `n_rho'"
                error 503
            }
            
            // Store rho parameters [Task-4.2, 4.5]
            forvalues j = 1/`n_rho' {
                matrix `RHO'[`g', `j'] = `_rho_g'[1, `j']
            }
            
            // Store sigma [Task-4.4, 4.5]
            matrix `SIGMA'[`g', 1] = e(sigma_eps_trim)
            
            // Verify sigma > 0
            if e(sigma_eps_trim) <= 0 {
                display as error ///
                    "omega recovery returned non-positive sigma_eps_trim"
                error 503
            }
            
            // Persist stable _pte_* objects so the public pte wrapper can keep
            // postestimation working after the grouped estimation restores the
            // original panel, even when ATT is skipped via noatt.
            local _keep_internal "`idvar' `timevar' `by' _pte_pf_esample"
            // Grouped public consumers need both the cached eps0
            // values and the exact support bridge used to validate or rebuild
            // residuals on the current data.
            local _pte_internal_stage12 "phi omega _pte_mid mid _pte_eps0 _pte_eps0_trim _pte_eps0_ind _pte_active_sample"
            if `do_att' {
                local _pte_internal_stage12 "`_pte_internal_stage12' _pte_nt _pte_tt _pte_tt_trim _pte_tt_raw"
            }
            foreach _v in `_pte_internal_stage12' {
                capture confirm variable `_v'
                if _rc == 0 {
                    local _keep_internal "`_keep_internal' `_v'"
                }
            }
            capture confirm variable `treatment'
            if _rc == 0 {
                local _keep_internal "`_keep_internal' `treatment'"
            }
            tempfile pte_bg_group_snapshot
            quietly save `"`pte_bg_group_snapshot'"', replace
            keep `_keep_internal'
            capture rename phi _pte_phi
            capture rename omega _pte_omega
            capture confirm variable _pte_mid
            if _rc {
                capture rename mid _pte_mid
            }
            capture confirm variable `treatment'
            if _rc == 0 {
                tempvar _pte_treat_firm_save
                quietly bysort `idvar': egen byte `_pte_treat_firm_save' = max(`treatment')
                quietly gen byte _pte_D = `treatment'
                quietly gen byte _pte_treat = (`_pte_treat_firm_save' > 0) if !missing(`_pte_treat_firm_save')
                quietly drop `_pte_treat_firm_save'
                quietly drop `treatment'
            }
            quietly save "`tempdir_base'_internal_`g'.dta", replace
            quietly use `"`pte_bg_group_snapshot'"', clear
            quietly xtset `idvar' `timevar'
            local internal_saved_groups "`internal_saved_groups' `g'"
            if "`internal_first_group'" == "" {
                local internal_first_group "`g'"
            }

            if `do_att' {
                // Stage 3: ATT estimation [Task-5]
                // Use the user/default inner seed parsed by syntax.
                _pte_att, treatment(`treatment') omegapoly(`omegapoly') ///
                    nsim(`nsim') attperiods(`attperiods') ///
                    seed(`seed') `_bg_eps0_legacy_opt' ///
                    `_bg_att_legacy_opt' `notrimeps' `_diag_opt'
                
                // Interface verification [Task-5.6]
                tempname _att_g _att_full
                matrix `_att_g' = e(att)
                local _ncol_att = colsof(`_att_g')
                matrix `_att_full' = J(1, `n_att', .)
                local _att_g_colnames : colnames `_att_g'
                forvalues _pte_att_j = 1/`_ncol_att' {
                    local _pte_att_name : word `_pte_att_j' of `_att_g_colnames'
                    if "`_pte_att_name'" == "avg" {
                        local _pte_att_col = `n_att'
                    }
                    else {
                        local _pte_att_period = real("`_pte_att_name'")
                        if missing(`_pte_att_period') | ///
                            `_pte_att_period' != floor(`_pte_att_period') | ///
                            `_pte_att_period' < 0 | `_pte_att_period' > `attperiods' {
                            display as error ///
                                "ATT period support out of grouped range: `_pte_att_name'"
                            error 503
                        }
                        local _pte_att_col = `_pte_att_period' + 1
                    }
                    matrix `_att_full'[1, `_pte_att_col'] = `_att_g'[1, `_pte_att_j']
                }
                
                // Store ATT [Task-5.7]
                forvalues j = 1/`n_att' {
                    matrix `ATT'[`g', `j'] = `_att_full'[1, `j']
                }
                
                // Refresh the internal worker snapshot so grouped ATT runs keep
                // the ATT-stage _pte_* payload in memory for postestimation.
                local _keep_internal "`idvar' `timevar' `by' _pte_pf_esample"
                foreach _v in phi omega _pte_mid mid _pte_eps0 _pte_eps0_trim ///
                    _pte_eps0_ind _pte_active_sample _pte_nt _pte_tt ///
                    _pte_tt_trim _pte_tt_raw {
                    capture confirm variable `_v'
                    if _rc == 0 {
                        local _keep_internal "`_keep_internal' `_v'"
                    }
                }
                capture confirm variable `treatment'
                if _rc == 0 {
                    local _keep_internal "`_keep_internal' `treatment'"
                }
                tempfile pte_bg_att_snapshot
                quietly save `"`pte_bg_att_snapshot'"', replace
                keep `_keep_internal'
                capture rename phi _pte_phi
                capture rename omega _pte_omega
                capture confirm variable _pte_mid
                if _rc {
                    capture rename mid _pte_mid
                }
                capture confirm variable `treatment'
                if _rc == 0 {
                    tempvar _pte_treat_firm_save2
                    quietly bysort `idvar': egen byte `_pte_treat_firm_save2' = max(`treatment')
                    quietly gen byte _pte_D = `treatment'
                    quietly gen byte _pte_treat = (`_pte_treat_firm_save2' > 0) if !missing(`_pte_treat_firm_save2')
                    quietly drop `_pte_treat_firm_save2'
                    quietly drop `treatment'
                }
                quietly save "`tempdir_base'_internal_`g'.dta", replace
                quietly use `"`pte_bg_att_snapshot'"', clear
                quietly xtset `idvar' `timevar'
                
                // _pte_att generates _pte_tt (firm-level TT) and _pte_nt (relative time)
                keep `idvar' `timevar' _pte_nt _pte_tt _pte_tt_trim _pte_tt_raw `by'
                rename _pte_nt nt
                rename _pte_tt TT_mean
                rename _pte_tt_trim TT_mean_trim
                rename _pte_tt_raw TT_mean_raw
                qui save "`tempdir_base'_tt_`g'.dta", replace
                local tt_saved_groups "`tt_saved_groups' `g'"
                if "`tt_first_group'" == "" {
                    local tt_first_group "`g'"
                }
            }
        }
        
        // 4.9 Error handling: mark missing on failure [Task-2.9]
        if _rc != 0 {
            if `first_fail_rc' == 0 {
                local first_fail_rc = _rc
            }
            display as error ///
                "Estimation failed for group `grp' (error code: " _rc ")"
            display as text ///
                "Marking group `g' results as missing, continuing..."
            // Matrices already initialized to missing (.), no need to reassign
            // Just ensure the group is flagged
        }
        else {
            local ++n_success_groups
        }
        
        // 4.10 Restore original data [Task-2.10]
        restore
    }

    if `n_success_groups' == 0 {
        if `first_fail_rc' == 0 {
            local first_fail_rc = 498
        }
        capture ereturn clear
        display as error ///
            "_pte_bygroup: all groups failed; no grouped estimation results can be posted"
        display as error ///
            "Fix the by()/industry() split or estimation support before rerunning grouped pte"
        exit `first_fail_rc'
    }
    
    if "`internal_saved_groups'" != "" {
        tempfile _pte_bygroup_internal_all
        preserve
        quietly use "`tempdir_base'_internal_`internal_first_group'.dta", clear
        foreach _g of local internal_saved_groups {
            if `_g' != `internal_first_group' {
                capture quietly append using "`tempdir_base'_internal_`_g'.dta", force
            }
        }
        capture drop `by'
        quietly save `"_pte_bygroup_internal_all"', replace
        restore

        foreach _v in _pte_pf_esample _pte_phi _pte_omega _pte_mid _pte_eps0 ///
            _pte_eps0_trim _pte_eps0_ind _pte_active_sample _pte_D ///
            _pte_treat _pte_nt _pte_tt _pte_tt_trim _pte_tt_raw {
            capture drop `_v'
        }
        quietly merge 1:1 `idvar' `timevar' using `"_pte_bygroup_internal_all"', nogenerate
    }

    // =========================================================================
    // 5. Step 3: ATT pooling via append + tabstat (Task-7)
    // =========================================================================
    
    if `do_att' & "`nolog'" == "" {
        display as text ""
        display as text "{hline 60}"
        display as text "Pooling ATT across groups..."
        display as text "{hline 60}"
    }
    
    // Merge all group-level TT data files
    local has_att_pool_trim = 0
    local has_att_pool_raw = 0
    if `do_att' {
        preserve
        qui use "`tempdir_base'_tt_`tt_first_group'.dta", clear
        foreach _g of local tt_saved_groups {
            if `_g' != `tt_first_group' {
                capture qui append using "`tempdir_base'_tt_`_g'.dta", force
            }
        }
        
        // Compute pooled ATT by relative time (nt)
        tempname ATT_pool ATT_pool_trim ATT_pool_raw ATT_sd ATT_N
        matrix `ATT_pool' = J(1, `n_att', .)
        matrix `ATT_pool_trim' = J(1, `n_att', .)
        matrix `ATT_pool_raw' = J(1, `n_att', .)
        matrix `ATT_sd'   = J(1, `n_att', .)
        matrix `ATT_N'    = J(1, `n_att', 0)
        capture confirm variable TT_mean_trim
        local has_att_pool_trim = (_rc == 0)
        capture confirm variable TT_mean_raw
        local has_att_pool_raw = (_rc == 0)
        
        forvalues _l = 0/`attperiods' {
            qui summarize TT_mean if nt == `_l'
            if r(N) > 0 {
                local _col = `_l' + 1
                matrix `ATT_pool'[1, `_col'] = r(mean)
                matrix `ATT_sd'[1, `_col']   = r(sd)
                matrix `ATT_N'[1, `_col']    = r(N)
                if `has_att_pool_trim' {
                    qui summarize TT_mean_trim if nt == `_l'
                    if r(N) > 0 {
                        matrix `ATT_pool_trim'[1, `_col'] = r(mean)
                    }
                }
                if `has_att_pool_raw' {
                    qui summarize TT_mean_raw if nt == `_l'
                    if r(N) > 0 {
                        matrix `ATT_pool_raw'[1, `_col'] = r(mean)
                    }
                }
            }
            else {
                if "`nodiagnose'" == "" {
                    display as text ///
                        "Warning: No observations for nt = `_l'"
                }
            }
        }
        
        // ATT_avg: mean across all valid nt periods (last column)
        qui summarize TT_mean if nt >= 0 & nt <= `attperiods'
        if r(N) > 0 {
            matrix `ATT_pool'[1, `n_att'] = r(mean)
            matrix `ATT_sd'[1, `n_att']   = r(sd)
            matrix `ATT_N'[1, `n_att']    = r(N)
        }
        if `has_att_pool_trim' {
            qui summarize TT_mean_trim if nt >= 0 & nt <= `attperiods'
            if r(N) > 0 {
                matrix `ATT_pool_trim'[1, `n_att'] = r(mean)
            }
        }
        if `has_att_pool_raw' {
            qui summarize TT_mean_raw if nt >= 0 & nt <= `attperiods'
            if r(N) > 0 {
                matrix `ATT_pool_raw'[1, `n_att'] = r(mean)
            }
        }
        
        // Column names for pooled matrices
        local pool_colnames ""
        forvalues _l = 0/`attperiods' {
            local pool_colnames "`pool_colnames' ATT_`_l'"
        }
        local pool_colnames "`pool_colnames' ATT_avg"
        matrix colnames `ATT_pool' = `pool_colnames'
        if `has_att_pool_trim' matrix colnames `ATT_pool_trim' = `pool_colnames'
        if `has_att_pool_raw' matrix colnames `ATT_pool_raw' = `pool_colnames'
        matrix colnames `ATT_sd'   = `pool_colnames'
        matrix colnames `ATT_N'    = `pool_colnames'
        
        restore
    }
    
    // =========================================================================
    // 6. Step 4: Bootstrap inference (Task-8, Task-8b)
    // =========================================================================
    
    tempname ATT_SE_pool
    
    if `do_att' & `bootstrap' > 0 {
        
        if "`nolog'" == "" {
            display as text ""
            display as text "{hline 60}"
            display as text "Bootstrap inference: `bootstrap' replications"
            display as text "{hline 60}"
        }
        
        tempname ATT_boot
        matrix `ATT_boot' = J(`bootstrap', `n_att', .)
        
        // Column names for ATT_boot
        matrix colnames `ATT_boot' = `pool_colnames'
        
        // ─────────────────────────────────────────────────────────────
        // Dual-layer seed management:
        //   Standard mode: Boot outer, industry inner. Seed set once
        //     outside industry loop. Random state flows naturally.
        //   Replicate mode: Industry outer, Boot inner. Seed reset
        //     per industry (matches replication loop structure).
        // ─────────────────────────────────────────────────────────────
        
        if "`replicate'" != "" {
            // ═══════════════════════════════════════════════════════════
            // Task-8b: Replicate mode (industry outer, boot inner)
            // Matches replication code structure:
            //   forv j=1/G { set seed X; forv b=1/B { ... } }
            // ═══════════════════════════════════════════════════════════
            
            local _g = 0
            foreach grp of local groups {
                local ++_g
                
                // Reset seed per industry (replication behavior)
                set seed `seed_boot'
                
                forvalues _b = 1/`bootstrap' {
                    preserve
                    
                    // Filter to current group
                    if "`_pte_byvar_type'" == "numeric" {
                        qui keep if `by' == `grp' & `touse'
                    }
                    else {
                        qui keep if `by' == "`grp'" & `touse'
                    }
                    
                    // Stratified cluster bootstrap
                    capture drop _pte_treat_flag
                    qui bysort `idvar': egen _pte_treat_flag = max(`treatment')
                    qui bsample, strata(_pte_treat_flag) ///
                        cluster(`idvar') idcluster(_pte_firm_b)
                    qui replace `idvar' = _pte_firm_b
                    qui tsset `idvar' `timevar'
                    
                    capture noisily {
                        _pte_prodfunc, treatment(`treatment') ///
                            id(`idvar') time(`timevar') ///
                            lny(`depvar') free(`free') state(`state') ///
                            proxy(`proxy') pfunc(`pfunc') poly(`poly') ///
                            omegapoly(`omegapoly') dopooledz `_pf_group_stage_opt' ///
                            `_pf_control_opt' `_diag_opt' noreport replace
                        
                        _pte_omega, treatment(`treatment') ///
                            omegapoly(`omegapoly') eps0window(`eps0window') ///
                            `_bg_eps0_legacy_opt' `notrimeps' `_diag_opt'
                        
                        // Bootstrap must preserve the grouped RNG stream
                        // once the outer/group seed has been set. Resetting
                        // _pte_att to the same seed every draw breaks the
                        // official industry bootstrap law.
                        _pte_att, treatment(`treatment') ///
                            omegapoly(`omegapoly') nsim(`nsim') ///
                            attperiods(`attperiods') ///
                            preserverng `_bg_eps0_legacy_opt' ///
                            `_bg_att_legacy_opt' `notrimeps' `_diag_opt'
                        
                        keep `idvar' `timevar' _pte_nt _pte_tt `by'
                        rename _pte_nt nt
                        rename _pte_tt TT_mean
                        qui save "`tempdir_base'_tt_`_g'_boot`_b'.dta", replace
                    }
                    
                    restore
                }
            }
            
            // Pooling phase: merge all industries per boot iteration
            forvalues _b = 1/`bootstrap' {
                preserve
                local _boot_first_group ""
                forvalues _g = 1/`n_groups' {
                    capture confirm file ///
                        "`tempdir_base'_tt_`_g'_boot`_b'.dta"
                    if _rc == 0 & "`_boot_first_group'" == "" {
                        local _boot_first_group "`_g'"
                    }
                }
                if "`_boot_first_group'" == "" {
                    restore
                    continue
                }

                qui use "`tempdir_base'_tt_`_boot_first_group'_boot`_b'.dta", clear
                forvalues _g = 1/`n_groups' {
                    if `_g' != `_boot_first_group' {
                        capture qui append using ///
                            "`tempdir_base'_tt_`_g'_boot`_b'.dta", force
                    }
                }
                
                forvalues _l = 0/`attperiods' {
                    qui summarize TT_mean if nt == `_l'
                    if r(N) > 0 {
                        local _col = `_l' + 1
                        matrix `ATT_boot'[`_b', `_col'] = r(mean)
                    }
                }
                qui summarize TT_mean if nt >= 0 & nt <= `attperiods'
                if r(N) > 0 {
                    matrix `ATT_boot'[`_b', `n_att'] = r(mean)
                }
                restore
            }
        }
        else {
            // ═══════════════════════════════════════════════════════════
            // Task-8: Standard mode (boot outer, industry inner)
            // Seed set once outside industry loop; random state flows
            // naturally across iterations.
            // ═══════════════════════════════════════════════════════════
            
            set seed `seed_boot'
            
            forvalues _b = 1/`bootstrap' {
                
                // Progress display every 50 iterations
                if "`nolog'" == "" & mod(`_b', 50) == 0 {
                    display as text ///
                        "  Bootstrap replication `_b' / `bootstrap'"
                }
                
                // Per-industry bootstrap estimation
                local _g = 0
                foreach grp of local groups {
                    local ++_g
                    
                    preserve
                    
                    // Filter to current group
                    if "`_pte_byvar_type'" == "numeric" {
                        qui keep if `by' == `grp' & `touse'
                    }
                    else {
                        qui keep if `by' == "`grp'" & `touse'
                    }
                    
                    // Stratified cluster bootstrap
                    capture drop _pte_treat_flag
                    qui bysort `idvar': egen _pte_treat_flag ///
                        = max(`treatment')
                    qui bsample, strata(_pte_treat_flag) ///
                        cluster(`idvar') idcluster(_pte_firm_b)
                    qui replace `idvar' = _pte_firm_b
                    qui tsset `idvar' `timevar'
                    
                    capture noisily {
                        _pte_prodfunc, treatment(`treatment') ///
                            id(`idvar') time(`timevar') ///
                            lny(`depvar') free(`free') state(`state') ///
                            proxy(`proxy') pfunc(`pfunc') poly(`poly') ///
                            omegapoly(`omegapoly') dopooledz `_pf_group_stage_opt' ///
                            `_pf_control_opt' `_diag_opt' noreport replace
                        
                        _pte_omega, treatment(`treatment') ///
                            omegapoly(`omegapoly') eps0window(`eps0window') ///
                            `_bg_eps0_legacy_opt' `notrimeps' `_diag_opt'
                        
                        // Keep the live grouped RNG stream inside bootstrap;
                        // the outer/group seed is already managed above.
                        _pte_att, treatment(`treatment') ///
                            omegapoly(`omegapoly') nsim(`nsim') ///
                            attperiods(`attperiods') ///
                            preserverng `_bg_eps0_legacy_opt' ///
                            `_bg_att_legacy_opt' `notrimeps' `_diag_opt'
                        
                        keep `idvar' `timevar' _pte_nt _pte_tt `by'
                        rename _pte_nt nt
                        rename _pte_tt TT_mean
                        qui save ///
                            "`tempdir_base'_tt_`_g'_boot`_b'.dta", replace
                    }
                    
                    restore
                }
                
                // Re-pool all industries for this bootstrap iteration
                preserve
                local _boot_first_group ""
                forvalues _g = 1/`n_groups' {
                    capture confirm file ///
                        "`tempdir_base'_tt_`_g'_boot`_b'.dta"
                    if _rc == 0 & "`_boot_first_group'" == "" {
                        local _boot_first_group "`_g'"
                    }
                }
                if "`_boot_first_group'" == "" {
                    restore
                    continue
                }

                qui use "`tempdir_base'_tt_`_boot_first_group'_boot`_b'.dta", clear
                forvalues _g = 1/`n_groups' {
                    if `_g' != `_boot_first_group' {
                        capture qui append using ///
                            "`tempdir_base'_tt_`_g'_boot`_b'.dta", force
                    }
                }
                
                forvalues _l = 0/`attperiods' {
                    qui summarize TT_mean if nt == `_l'
                    if r(N) > 0 {
                        local _col = `_l' + 1
                        matrix `ATT_boot'[`_b', `_col'] = r(mean)
                    }
                }
                qui summarize TT_mean if nt >= 0 & nt <= `attperiods'
                if r(N) > 0 {
                    matrix `ATT_boot'[`_b', `n_att'] = r(mean)
                }
                restore
            }
        }
        
        // Compute pooled bootstrap SE with a compiled Mata helper.
        tempname _pte_bg_test_mat
        matrix `_pte_bg_test_mat' = (1)
        capture mata: _pte_bygroup_boot_se("`_pte_bg_test_mat'", "`_pte_bg_test_mat'")
        if _rc {
            qui findfile _pte_bygroup_helpers.mata
            local _pte_bg_helper_path `"`r(fn)'"'
            qui do `"`_pte_bg_helper_path'"'
        }
        matrix drop `_pte_bg_test_mat'

        mata: _pte_bygroup_boot_se("`ATT_boot'", "`ATT_SE_pool'")
        
    }
    if `do_att' & `bootstrap' > 0 matrix colnames `ATT_SE_pool' = `pool_colnames'
    
    // =========================================================================
    // 7. Step 5: ereturn assembly and display (Task-9, Task-10)
    // =========================================================================
    
    // ─────────────────────────────────────────────────────────────────────
    // Task-9: ereturn assembly
    // ─────────────────────────────────────────────────────────────────────
    
    ereturn clear
    
    // Matrices
    ereturn matrix b_by       = `BETA'
    ereturn matrix rho_by     = `RHO'
    ereturn matrix sigma_by   = `SIGMA'
    ereturn matrix N_by       = `N_OBS'
    ereturn matrix N_firms_by = `N_FIRMS'
    if `do_att' {
        ereturn matrix att_by   = `ATT'
        ereturn matrix att_pool = `ATT_pool'
        if `has_att_pool_trim' {
            ereturn matrix att_pool_trim = `ATT_pool_trim'
        }
        if `has_att_pool_raw' {
            ereturn matrix att_pool_raw = `ATT_pool_raw'
        }
        ereturn matrix att_sd = `ATT_sd'
        ereturn matrix att_N  = `ATT_N'
    }
    
    if `do_att' & `bootstrap' > 0 {
        ereturn matrix att_se_pool = `ATT_SE_pool'
    }
    
    // Scalars
    ereturn scalar n_groups   = `n_groups'
    ereturn scalar omegapoly  = `omegapoly'
    ereturn scalar attperiods = `attperiods'
    ereturn scalar attperiods_max = `attperiods'
    ereturn scalar nsim       = `nsim'
    ereturn scalar bootstrap  = `bootstrap'
    ereturn scalar seed       = `seed'
    ereturn scalar eps0window = `eps0window'
    ereturn scalar noatt      = !`do_att'
    
    // Macros
    ereturn local by       "`by'"
    ereturn local groups   "`groups'"
    ereturn local depvar   "`depvar'"
    ereturn local pfunc    "`pfunc'"
    ereturn local cmd      "_pte_bygroup"
    
    // ─────────────────────────────────────────────────────────────────────
    // Task-10: Output report display
    // ─────────────────────────────────────────────────────────────────────
    
    if "`nolog'" == "" {
        
        display as text ""
        display as text "{hline 78}"
        display as text "PTE Bygroup Estimation Results"
        display as text "{hline 78}"
        
        if `do_att' {
            // Table header: dynamic columns based on attperiods
            display as text _col(1) "`by'" _col(12) "N" _col(20) "Firms" ///
                _continue
            forvalues _l = 0/`attperiods' {
                local _col_pos = 28 + `_l' * 12
                display as text _col(`_col_pos') "ATT_`_l'" _continue
            }
            local _avg_pos = 28 + (`attperiods' + 1) * 12
            display as text _col(`_avg_pos') "ATT_avg"
            display as text "{hline 78}"
            
            // Per-group rows
            local _g = 0
            foreach grp of local groups {
                local ++_g
                display as text _col(1) "`grp'" ///
                    _col(10) %8.0f el(e(N_by), `_g', 1) ///
                    _col(20) %6.0f el(e(N_firms_by), `_g', 1) ///
                    _continue
                forvalues _l = 0/`attperiods' {
                    local _col_pos = 28 + `_l' * 12
                    local _j = `_l' + 1
                    display as text _col(`_col_pos') ///
                        %8.4f el(e(att_by), `_g', `_j') _continue
                }
                local _avg_pos = 28 + (`attperiods' + 1) * 12
                display as text _col(`_avg_pos') ///
                    %8.4f el(e(att_by), `_g', `n_att')
            }
            
            display as text "{hline 78}"
            
            // Pooled row
            display as text _col(1) "Pooled" _continue
            forvalues _l = 0/`attperiods' {
                local _col_pos = 28 + `_l' * 12
                local _j = `_l' + 1
                display as text _col(`_col_pos') ///
                    %8.4f el(e(att_pool), 1, `_j') _continue
            }
            local _avg_pos = 28 + (`attperiods' + 1) * 12
            display as text _col(`_avg_pos') ///
                %8.4f el(e(att_pool), 1, `n_att')
            
            // Bootstrap SE row (if applicable)
            if `bootstrap' > 0 {
                display as text _col(1) "  (SE)" _continue
                forvalues _l = 0/`attperiods' {
                    local _col_pos = 28 + `_l' * 12
                    local _j = `_l' + 1
                    display as text _col(`_col_pos') ///
                        "(" %6.4f el(e(att_se_pool), 1, `_j') ")" ///
                        _continue
                }
                local _avg_pos = 28 + (`attperiods' + 1) * 12
                display as text _col(`_avg_pos') ///
                    "(" %6.4f el(e(att_se_pool), 1, `n_att') ")"
            }
            
            display as text "{hline 78}"
            display as text "Note: ATT computed via enterprise-level pooling" ///
                " (append + mean)"
            display as text "      omegapoly = " e(omegapoly) ///
                ", nsim = " e(nsim) ", attperiods = " e(attperiods_max)
            if `bootstrap' > 0 {
                display as text "      Bootstrap replications = " ///
                    e(bootstrap)
            }
        }
        else {
            display as text "Grouped production/evolution payload computed; ATT skipped (noatt)."
            display as text "Use e(b_by), e(rho_by), e(sigma_by), e(N_by), and e(N_firms_by) for grouped stage-1/2 summaries."
            display as text "{hline 78}"
        }
    }

end
