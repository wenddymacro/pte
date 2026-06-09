*! _pte_group_worker.ado
*! Worker program invoked by each parallel instance.
*! Reads parameters from PTE_PAR_* globals, iterates over assigned groups,
*! Single group failure does not stop other groups.

version 14.0
capture program drop _pte_group_worker
program define _pte_group_worker
    version 14.0
    
    // =========================================================================
    // 1. Read parameters from global macros (set by _pte_parallel_groups)
    // =========================================================================
    
    // Determine worker ID from parallel package
    // parallel sets $pll_instance (1-based worker index)
    local worker_id = ${pll_instance}
    if `worker_id' == . | `worker_id' < 1 {
        // Fallback: try argument
        args worker_id_arg
        if "`worker_id_arg'" != "" {
            local worker_id = `worker_id_arg'
        }
        else {
            display as error "_pte_group_worker: cannot determine worker ID"
            exit 198
        }
    }
    
    // Read assigned groups for this worker
    local my_groups "${PTE_PAR_TASKS_`worker_id'}"
    if `"`my_groups'"' == "" {
        // No groups assigned to this worker, exit silently
        exit
    }
    
    // Read estimation parameters from globals
    local master_data  "${PTE_PAR_MASTER_DATA}"
    local resultbase   "${PTE_PAR_RESULTBASE}"
    local by           "${PTE_PAR_BY}"
    local byvar_type   "${PTE_PAR_BYVAR_TYPE}"
    local depvar       "${PTE_PAR_DEPVAR}"
    local free         "${PTE_PAR_FREE}"
    local state        "${PTE_PAR_STATE}"
    local proxy        "${PTE_PAR_PROXY}"
    local treatment    "${PTE_PAR_TREATMENT}"
    local control      "${PTE_PAR_CONTROL}"
    local pfunc        "${PTE_PAR_PFUNC}"
    local poly         "${PTE_PAR_POLY}"
    local omegapoly    "${PTE_PAR_OMEGAPOLY}"
    local eps0window   "${PTE_PAR_EPS0WINDOW}"
    local nsim         "${PTE_PAR_NSIM}"
    local attperiods   "${PTE_PAR_ATTPERIODS}"
    local seed         "${PTE_PAR_SEED}"
    local notrimeps    "${PTE_PAR_NOTRIMEPS}"
    local panelvar     "${PTE_PAR_PANELVAR}"
    local timevar_cfg  "${PTE_PAR_TIMEVAR}"
    local xtdelta      "${PTE_PAR_XTDELTA}"
    local tousevar     "${PTE_PAR_TOUSEVAR}"
    
    // Build notrimeps option string
    local notrimeps_opt ""
    if "`notrimeps'" != "" {
        local notrimeps_opt "notrimeps"
    }
    
    // =========================================================================
    // 2. Parameter validation (TASK-014.2)
    // =========================================================================
    
    if "`master_data'" == "" {
        display as error ///
            "_pte_group_worker `worker_id': master_data global not set"
        exit 198
    }
    
    capture confirm file "`master_data'"
    if _rc != 0 {
        display as error ///
            "_pte_group_worker `worker_id': master data file not found"
        exit 601
    }
    
    if "`by'" == "" | "`depvar'" == "" | "`treatment'" == "" {
        display as error ///
            "_pte_group_worker `worker_id': required parameters missing"
        exit 198
    }
    if "`tousevar'" == "" {
        display as error ///
            "_pte_group_worker `worker_id': touse bridge not set"
        exit 198
    }
    if "`panelvar'" == "" | "`timevar_cfg'" == "" {
        display as error ///
            "_pte_group_worker `worker_id': panel metadata bridge not set"
        exit 198
    }

    local _pte_n_controls : word count `control'
    if "`pfunc'" == "cd" {
        local n_beta_struct = 2
    }
    else {
        local n_beta_struct = 5
    }
    local n_beta = `n_beta_struct' + 1
    if `_pte_n_controls' > 1 {
        local n_beta = `n_beta_struct' + `_pte_n_controls'
    }
    local n_rho = `omegapoly' + 1
    local n_att = `attperiods' + 2
    
    // =========================================================================
    // 3. Map group values to global indices (TASK-015)
    // =========================================================================
    
    // We need the global group index for each assigned group
    // to save results with the correct index suffix.
    // Read all groups from the master data to build the mapping.
    
    preserve
    qui use "`master_data'", clear

    // Validate the touse bridge on the master-data payload, not on whatever
    // dataset happens to be live in the child session before loading.
    capture confirm variable `tousevar', exact
    if _rc != 0 {
        display as error ///
            "_pte_group_worker `worker_id': touse bridge `tousevar' not found in master data"
        exit 111
    }
    capture confirm numeric variable `tousevar'
    if _rc != 0 {
        display as error ///
            "_pte_group_worker `worker_id': touse bridge `tousevar' must be numeric"
        exit 111
    }
    
    // Rebuild the panel declaration explicitly; the worker cannot rely on
    // xtset metadata being preserved when the master payload is reloaded in a
    // fresh child session.
    local _pte_xt_rc = 0
    if "`xtdelta'" != "" & "`xtdelta'" != "." & "`xtdelta'" != "1" {
        capture quietly xtset `panelvar' `timevar_cfg', delta(`xtdelta')
        local _pte_xt_rc = _rc
    }
    else {
        capture quietly xtset `panelvar' `timevar_cfg'
        local _pte_xt_rc = _rc
    }
    if `_pte_xt_rc' != 0 {
        display as error ///
            "_pte_group_worker `worker_id': failed to rebuild xtset from panel metadata bridge"
        exit `_pte_xt_rc'
    }

    // Get panel structure
    capture _xt, trequired
    if _rc != 0 {
        display as error ///
            "_pte_group_worker `worker_id': data not xtset"
        exit 459
    }
    local idvar = r(ivar)
    local timevar = r(tvar)
    
    // Get full group list for index mapping
    if "`byvar_type'" == "numeric" {
        qui levelsof `by' if `tousevar', local(all_groups)
    }
    else {
        // Keep compound quotes so embedded spaces remain one group token.
        qui levelsof `by' if `tousevar', local(all_groups)
    }
    restore
    
    // =========================================================================
    // 4. Main group loop (TASK-014.3, TASK-015~018)
    // =========================================================================
    
    local n_completed = 0
    local n_failed = 0
    
    foreach grp of local my_groups {
        
        // Find global index for this group value
        local _gi = 0
        local _found = 0
        foreach _ag of local all_groups {
            local ++_gi
            if "`_ag'" == "`grp'" {
                local _found = 1
                continue, break
            }
        }
        
        if !`_found' {
            display as error ///
                "_pte_group_worker `worker_id': group `grp' not in data"
            local ++n_failed
            continue
        }
        
        // ─────────────────────────────────────────────────────────────
        // 4.1 Load and filter data (TASK-015)
        // ─────────────────────────────────────────────────────────────
        preserve
        qui use "`master_data'", clear
        
        if "`byvar_type'" == "numeric" {
            qui keep if `by' == `grp' & `tousevar'
        }
        else {
            qui keep if `by' == "`grp'" & `tousevar'
        }
        
        qui count
        local _nobs = r(N)
        
        // Count unique firms
        tempvar _tag
        qui egen `_tag' = tag(`idvar')
        qui count if `_tag' == 1
        local _nfirms = r(N)

        // Clear any leftover payload for this group/run before estimation.
        // The orchestrator should pass a fresh resultbase, but worker-side
        // cleanup keeps stale files from being mistaken for current success.
        capture erase "`resultbase'_status_`_gi'.dta"
        capture erase "`resultbase'_params_`_gi'.dta"
        capture erase "`resultbase'_tt_`_gi'.dta"
        
        // ─────────────────────────────────────────────────────────────
        // 4.2 Estimation: prodfunc -> omega -> att (TASK-016)
        // ─────────────────────────────────────────────────────────────
        capture noisily {
            
            // Stage 1: Production function estimation
            local _pf_opts "treatment(`treatment') id(`idvar')"
            local _pf_opts "`_pf_opts' time(`timevar')"
            local _pf_opts "`_pf_opts' lny(`depvar') free(`free')"
            local _pf_opts "`_pf_opts' state(`state')"
            local _pf_opts "`_pf_opts' proxy(`proxy') pfunc(`pfunc')"
            local _pf_opts "`_pf_opts' poly(`poly')"
            local _pf_opts "`_pf_opts' omegapoly(`omegapoly')"
            local _pf_opts "`_pf_opts' noreport replace"
            if "`control'" != "" {
                local _pf_opts "`_pf_opts' control(`control')"
            }
            
            _pte_prodfunc, `_pf_opts'
            
            // Capture grouped beta contract: single-control paths keep beta_t,
            // while multi-control paths append exact stage-1 control names.
            tempname _beta_g
            matrix `_beta_g' = e(b)
            local _beta_t_g = .
            local _pte_beta_payload_ctrl_ready = 1
            capture matrix _pte_beta_ctrl = e(beta_controls)
            if _rc == 0 {
                local _pte_beta_ctrl_names : colnames _pte_beta_ctrl
                if `_pte_n_controls' > 1 {
                    foreach _ctrl of local control {
                        local _ctrl_pos : list posof "`_ctrl'" in _pte_beta_ctrl_names
                        if `_ctrl_pos' < 1 {
                            local _pte_beta_payload_ctrl_ready = 0
                        }
                    }
                }
                else if "`control'" != "" {
                    local _only_ctrl : word 1 of `control'
                    local _ctrl_pos : list posof "`_only_ctrl'" in _pte_beta_ctrl_names
                    if `_ctrl_pos' < 1 {
                        local _pte_beta_payload_ctrl_ready = 0
                    }
                    else {
                        local _beta_t_g = _pte_beta_ctrl[1, `_ctrl_pos']
                    }
                }
                else if colsof(_pte_beta_ctrl) >= 1 {
                    local _beta_t_g = _pte_beta_ctrl[1, 1]
                }
            }
            else {
                capture local _beta_t_g = _b[t]
                if `_pte_n_controls' > 1 {
                    local _pte_beta_payload_ctrl_ready = 0
                }
            }
            
            // Stage 2: Evolution parameters
            _pte_omega, treatment(`treatment') ///
                omegapoly(`omegapoly') ///
                eps0window(`eps0window') ///
                `notrimeps_opt' nodiagnose
            
            // Capture rho and sigma
            tempname _rho_g
            matrix `_rho_g' = e(rho_0)
            local _sigma_g = e(sigma_eps_trim)
            
            // Stage 3: ATT estimation
            // Respect the seed forwarded by the orchestrator so serial and
            // parallel paths share the same reproducibility contract.
            _pte_att, treatment(`treatment') ///
                omegapoly(`omegapoly') ///
                nsim(`nsim') attperiods(`attperiods') ///
                seed(`seed') `notrimeps_opt' nodiagnose
            
            // Capture ATT
            tempname _att_g
            matrix `_att_g' = e(att)
            
            // ─────────────────────────────────────────────────────
            // 4.3 Save results to files (TASK-017)
            // ─────────────────────────────────────────────────────
            
            // Save firm-level TT data, preserving the dual-track ATT payload
            // when publishes trimmed/raw aliases.
            local _tt_keep "`idvar' `timevar' _pte_nt _pte_tt `by'"
            capture confirm variable _pte_tt_trim
            if _rc == 0 {
                local _tt_keep "`_tt_keep' _pte_tt_trim"
            }
            capture confirm variable _pte_tt_raw
            if _rc == 0 {
                local _tt_keep "`_tt_keep' _pte_tt_raw"
            }
            keep `_tt_keep'
            rename _pte_nt nt
            rename _pte_tt TT_mean
            capture rename _pte_tt_trim TT_mean_trim
            capture rename _pte_tt_raw TT_mean_raw
            qui save "`resultbase'_tt_`_gi'.dta", replace
            
            // Save parameter scalars to single-obs dataset
            clear
            qui set obs 1
            
            // Beta parameters
            local _ncol_beta = colsof(`_beta_g')
            forvalues j = 1/`_ncol_beta' {
                qui gen double _pte_beta_`j' = ///
                    `_beta_g'[1, `j']
            }
            if `_pte_n_controls' > 1 {
                if `_pte_beta_payload_ctrl_ready' == 0 {
                    error 503
                }
                foreach _ctrl of local control {
                    local _ctrl_j = `: list posof "`_ctrl'" in control'
                    local _beta_col = `n_beta_struct' + `_ctrl_j'
                    local _ctrl_pos : list posof "`_ctrl'" in _pte_beta_ctrl_names
                    qui gen double _pte_beta_`_beta_col' = ///
                        _pte_beta_ctrl[1, `_ctrl_pos']
                }
            }
            else if !missing(`_beta_t_g') {
                qui gen double _pte_beta_`n_beta' = `_beta_t_g'
            }
            
            // Rho parameters
            local _ncol_rho = colsof(`_rho_g')
            forvalues j = 1/`_ncol_rho' {
                qui gen double _pte_rho_`j' = ///
                    `_rho_g'[1, `j']
            }
            
            // Sigma
            qui gen double _pte_sigma = `_sigma_g'
            
            // ATT values
            local _ncol_att = colsof(`_att_g')
            forvalues j = 1/`_ncol_att' {
                qui gen double _pte_att_`j' = ///
                    `_att_g'[1, `j']
            }
            
            // Sample info
            qui gen double _pte_nobs = `_nobs'
            qui gen double _pte_nfirms = `_nfirms'
            
            qui save "`resultbase'_params_`_gi'.dta", ///
                replace
        }
        
        // ─────────────────────────────────────────────────────────
        // 4.4 Error handling (TASK-018)
        // ─────────────────────────────────────────────────────────
        local _group_rc = _rc
        if `_group_rc' != 0 {
            clear
            qui set obs 1
            qui gen byte _pte_success = 0
            qui gen double _pte_rc = `_group_rc'
            qui save "`resultbase'_status_`_gi'.dta", replace
            display as error ///
                "Worker `worker_id': Group `grp'" ///
                " (index `_gi') failed (rc=" `_group_rc' ")"
            local ++n_failed
        }
        else {
            clear
            qui set obs 1
            qui gen byte _pte_success = 1
            qui gen double _pte_rc = 0
            qui save "`resultbase'_status_`_gi'.dta", replace
            local ++n_completed
        }
        
        restore
    }
    
    // =========================================================================
    // 5. Summary
    // =========================================================================
    
    local n_total = `n_completed' + `n_failed'
    display as text ///
        "Worker `worker_id': completed " ///
        "`n_completed'/`n_total' groups" ///
        " (`n_failed' failed)"
    
end
