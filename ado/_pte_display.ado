*! _pte_display.ado

version 14.0
program define _pte_display
    version 14.0
    
    syntax [, NOLog NOAtt BY(varname) AGGregate Level(cilevel) VERBose]

    // Replay can omit by(), but an absent e(by) is read back as "." via
    // Stata's expression assignment; normalize that sentinel to blank before
    // using it as a grouped-path switch.
    if `"`by'"' == "." {
        local by ""
    }
    if "`by'" == "" {
        capture local replay_by = e(by)
        if _rc == 0 {
            if `"`replay_by'"' == "." {
                local replay_by ""
            }
        }
        local replay_groups ""
        capture local replay_groups = e(groups)
        if _rc == 0 & `"`replay_groups'"' == "." {
            local replay_groups ""
        }
        quietly _pte_has_grouped_replay_state
        local replay_has_grouped_state = r(has_grouped_replay)
        local replay_grouped_payloads `"`r(grouped_payloads)'"'
        // If grouped payloads exist but e(by) is absent, fall back to
        // non-grouped display path (att_sd and similar matrices are also
        // produced in non-grouped mode, so their presence alone does not
        // imply a grouped estimation).
        if `replay_has_grouped_state' & `"`replay_by'"' == "" {
            // Silent fallback: treat as non-grouped
        }
        if _rc == 0 & `"`replay_by'"' != "" {
            local by "`replay_by'"
        }
    }
    local is_bygroup = (`"`by'"' != "")
    
    // Default confidence level
    if "`level'" == "" local level = 95

    // Live bygroup worker results carry grouped payloads that differ from the
    // serial e(b)/rho_0/att_table contract. Keep the common header/sample
    // sections, then use grouped fallbacks in the parameter/evolution blocks.
    // noatt grouped replay has no ATT matrices, so rho_by is also a live-path
    // marker for grouped evolution replay.
    local is_live_bygroup = 0
    local has_live_point = 0
    if `is_bygroup' {
        capture confirm matrix e(att_by)
        if _rc == 0 {
            local is_live_bygroup = 1
            local has_live_point = 1
        }
        capture confirm matrix e(att_mean_pool)
        if _rc == 0 local is_live_bygroup = 1
        capture confirm matrix e(rho_by)
        if _rc == 0 local is_live_bygroup = 1
    }
    if `is_live_bygroup' {
        local grouped_labels ""
        capture local grouped_labels = e(groups)
        if _rc == 0 & `"`grouped_labels'"' == "." {
            local grouped_labels ""
        }
        if `"`grouped_labels'"' == "" {
            di as error "pte replay requires e(groups)"
            exit 301
        }

        // Grouped point replay must carry the grouped evolution law. Without
        // e(rho_by), replay would wrongly degrade into the grouped-bootstrap
        // display branch and mislabel an incomplete point payload.
        if `has_live_point' {
            capture confirm matrix e(rho_by)
            if _rc != 0 {
                di as error "pte replay requires e(rho_by)"
                exit 301
            }
        }
        if "`nolog'" == "" {
            _pte_display_header, level(`level')
            _pte_display_sample, bygroup
        }
        _pte_display_prodfunc, level(`level') bygrouplive
        _pte_display_evolution, bygrouplive
        if "`noatt'" == "" {
            _pte_display_bygroup, by(`by') level(`level') `aggregate'
        }
        else {
            _pte_display_noatt_msg
        }
        exit
    }

    // ─── Compact display mode (default when verbose is not specified) ───
    if "`verbose'" == "" {
        _pte_display_compact, `noatt' level(`level')
        exit
    }
    
    // ─── Full verbose display (original behavior) ───
    // Pre-requisite validation
    _pte_display_validate_deps, `noatt' `=cond(`is_bygroup', "bygroup", "")'
    
    // Display header and sample info (suppressed by nolog)
    if "`nolog'" == "" {
        _pte_display_header, level(`level')
        if `is_bygroup' {
            _pte_display_sample, bygroup
        }
        else {
            _pte_display_sample
        }
    }
    
    // Production function parameters (always shown)
    _pte_display_prodfunc, level(`level')
    
    // Evolution parameters (always shown)
    _pte_display_evolution
    
    // ATT results or skip message
    if `is_bygroup' {
        if "`noatt'" == "" {
            _pte_display_bygroup, by(`by') level(`level') `aggregate'
        }
        else {
            _pte_display_noatt_msg
        }
    }
    else {
        if "`noatt'" == "" {
            _pte_display_att, level(`level')
        }
        else {
            _pte_display_noatt_msg
        }
    }
end

program define _pte_display_validate_deps
    version 14.0
    
    syntax [, NOAtt BYGROUP]
    
    // Check e(b) exists
    capture matrix list e(b)
    if _rc != 0 {
        // e(b) not available - prodfunc display will be skipped
        // This is expected when e(b)/e(V) are stored as scalars
        local _pte_no_bV = 1
    }
    else {
        local _pte_no_bV = 0
    }
    
    // Check e(V) exists (only if e(b) exists)
    if `_pte_no_bV' == 0 {
        capture matrix list e(V)
        if _rc != 0 {
            local _pte_no_bV = 1
        }
        else {
            // Check dimension match
            // Note: colsof() requires a matrix name, not e(b) directly
            tempname _chk_b _chk_V
            matrix `_chk_b' = e(b)
            matrix `_chk_V' = e(V)
            local nb = colsof(`_chk_b')
            local nv = colsof(`_chk_V')
            if `nb' != `nv' {
                di as error "_pte_display: e(b) and e(V) dimension mismatch"
                di as error "  e(b) has `nb' columns, e(V) has `nv' columns"
                exit 503
            }
        }
    }
    
    // Check critical scalars
    capture scalar _tmp = e(omegapoly)
    if _rc != 0 {
        di as error "_pte_display: e(omegapoly) not found"
        exit 301
    }
    capture scalar drop _tmp
    
    capture scalar _tmp = e(sigma_eps_trim)
    if _rc != 0 {
        di as error "_pte_display: e(sigma_eps_trim) not found"
        exit 301
    }
    capture scalar drop _tmp
    
    // Check rho_0 matrix
    capture matrix list e(rho_0)
    if _rc != 0 {
        di as error "_pte_display: e(rho_0) not found"
        exit 301
    }
    
    // Check ATT results if needed
    if "`noatt'" == "" {
        if "`bygroup'" != "" {
            // Live bygroup replay publishes group-specific matrices rather than
            // the baseline att_table/result_table_raw bundle.
            capture matrix list e(att_by)
            if _rc != 0 {
                capture matrix list e(att_mean_pool)
                if _rc != 0 {
                    // Legacy bygroup mocks/tests still use the older display
                    // contract; allow them as a compatibility fallback.
                    capture matrix list e(att_bygroup)
                    if _rc != 0 {
                        capture matrix list e(att_table)
                        if _rc != 0 {
                            di as error "_pte_display: no by-group ATT payload found for replay"
                            exit 301
                        }
                    }
                }
            }
        }
        else {
            // Primary: use att_table (nperiods x 5: nt ATT sd N se)
            // Fallback: use result_table_raw (bootstrap path)
            local _pte_needs_trim_total = 0
            capture confirm matrix e(result_table_trim)
            if _rc == 0 {
                local _pte_needs_trim_total = 1
            }
            capture matrix list e(att_table)
            if _rc != 0 {
                capture matrix list e(result_table_raw)
                if _rc != 0 {
                    di as error "_pte_display: e(att_table) not found. Run pte with ATT estimation."
                    exit 301
                }
            }
            if `_pte_needs_trim_total' {
                capture scalar _tmp = e(ATT_avg_trim)
                if _rc != 0 {
                    tempname _pte_trim_tab
                    matrix `_pte_trim_tab' = e(result_table_trim)
                    local _pte_trim_rows = rowsof(`_pte_trim_tab')
                    local _pte_trim_nt = el(`_pte_trim_tab', `_pte_trim_rows', 1)
                    if missing(`_pte_trim_nt') | `_pte_trim_nt' >= 0 {
                        di as error "pte replay requires e(ATT_avg_trim)"
                        exit 301
                    }
                }
                capture scalar drop _tmp
            }
            else {
                capture scalar _tmp = e(ATT_avg)
                if _rc != 0 {
                    di as error "pte replay requires e(ATT_avg)"
                    exit 301
                }
                capture scalar drop _tmp
            }
        }
    }
end


// =========================================================================
// Unicode/ASCII fallback helper
// =========================================================================

program define _pte_unicode_or_ascii, sclass
    version 14.0
    args unicode_str ascii_str
    
    // Detect Unicode support by checking Stata version
    // Stata 14+ supports Unicode natively
    local stata_ver = c(stata_version)
    
    if `stata_ver' >= 14 {
        // Try to display a Unicode character to test support
        capture {
            local _test_unicode = ustrunescape("\u03c1")
        }
        if _rc == 0 {
            sreturn local result "`unicode_str'"
        }
        else {
            sreturn local result "`ascii_str'"
        }
    }
    else {
        sreturn local result "`ascii_str'"
    }
end


// =========================================================================
// Header display
// =========================================================================

program define _pte_display_header
    version 14.0
    syntax [, Level(cilevel)]
    
    // Title
    di as text _n "{hline 78}"
    di as text "Productivity Treatment Effects Estimation"
    di as text "{hline 78}"
    
    // Production function type
    local pfunc = "`e(pfunc)'"
    if "`pfunc'" == "cd" {
        local pfunc_display "Cobb-Douglas"
    }
    else {
        local pfunc_display "Translog"
    }
    
    di as text "Production function" _col(25) "=" _col(27) as result "`pfunc_display'"
    di as text "Method" _col(25) "=" _col(27) as result "ACF with CLK correction"
    
    // Trimeps status
    local notrimeps = "`e(notrimeps)'"
    if "`notrimeps'" == "" {
        local trim_status "on (1%-99%)"
    }
    else {
        local trim_status "off"
    }
    di as text "Trim eps0" _col(25) "=" _col(27) as result "`trim_status'"
    
    // Evolution order
    di as text "Evolution order" _col(25) "=" _col(27) as result %3.0f e(omegapoly)
    
    // Confidence level
    di as text "Confidence level" _col(25) "=" _col(27) as result "`level'%"
    
    di as text "{hline 78}"
end


// =========================================================================
// Sample information display
// =========================================================================

program define _pte_display_sample
    version 14.0
    syntax [, BYGROUP]
    
    // Total observations
    di as text "Number of obs" _col(25) "=" _col(27) as result %10.0fc e(N)
    
    // Number of firms
    capture local ng = e(N_g)
    if "`bygroup'" != "" {
        capture confirm matrix e(N_firms_by)
        if _rc == 0 {
            tempname n_firms_by
            matrix `n_firms_by' = e(N_firms_by)
            local ng = 0
            forvalues i = 1/`=rowsof(`n_firms_by')' {
                forvalues j = 1/`=colsof(`n_firms_by')' {
                    local n_firms_ij = el(`n_firms_by', `i', `j')
                    if !missing(`n_firms_ij') {
                        local ng = `ng' + `n_firms_ij'
                    }
                }
            }
        }
    }
    else if _rc != 0 | missing(`ng') {
        capture confirm matrix e(N_firms_by)
        if _rc == 0 {
            tempname n_firms_by
            matrix `n_firms_by' = e(N_firms_by)
            local ng = 0
            forvalues i = 1/`=rowsof(`n_firms_by')' {
                forvalues j = 1/`=colsof(`n_firms_by')' {
                    local n_firms_ij = el(`n_firms_by', `i', `j')
                    if !missing(`n_firms_ij') {
                        local ng = `ng' + `n_firms_ij'
                    }
                }
            }
        }
    }
    if !missing(`ng') {
        di as text "Number of firms" _col(25) "=" _col(27) as result %10.0fc `ng'
    }
    
    // Transition observations
    capture local ntrans = e(N_trans)
    if _rc == 0 & !missing(`ntrans') {
        di as text "Transition obs" _col(25) "=" _col(27) as result %10.0fc `ntrans' ///
            as text " (excluded from GMM)"
    }
    
    // Treated firms
    capture local ntreated = e(N_treated)
    if _rc == 0 & !missing(`ntreated') {
        di as text "Treated firms" _col(25) "=" _col(27) as result %10.0fc `ntreated'
    }
    
    // Control firms
    capture local ncontrol = e(N_control)
    if _rc == 0 & !missing(`ncontrol') {
        di as text "Control firms" _col(25) "=" _col(27) as result %10.0fc `ncontrol'
    }
    
    // Serial paths summarize panel length by firm; grouped paths summarize
    // observations by benchmark group.
    local sample_span_label "Obs per firm:"
    if "`bygroup'" != "" {
        local sample_span_label "Obs per group:"
    }

    // Observation span summary: min/avg/max
    capture local tmin_val = e(tmin)
    capture local tmean_val = e(tmean)
    capture local tmax_val = e(tmax)
    if missing(`tmin_val') | missing(`tmean_val') | missing(`tmax_val') {
        capture confirm matrix e(N_by)
        if _rc == 0 {
            tempname n_by
            matrix `n_by' = e(N_by)
            local nrows = rowsof(`n_by')
            if `nrows' > 0 {
                local tmin_val = .
                local tmax_val = .
                local tsum_val = 0
                forvalues i = 1/`nrows' {
                    local n_i = el(`n_by', `i', 1)
                    if !missing(`n_i') {
                        if missing(`tmin_val') | `n_i' < `tmin_val' {
                            local tmin_val = `n_i'
                        }
                        if missing(`tmax_val') | `n_i' > `tmax_val' {
                            local tmax_val = `n_i'
                        }
                        local tsum_val = `tsum_val' + `n_i'
                    }
                }
                local tmean_val = `tsum_val' / `nrows'
            }
        }
    }
    if !missing(`tmin_val') & !missing(`tmean_val') & !missing(`tmax_val') {
        di as text "`sample_span_label'" _col(25) ///
            as text "min = " as result %4.0f `tmin_val' ///
            as text "  avg = " as result %6.1f `tmean_val' ///
            as text "  max = " as result %4.0f `tmax_val'
    }
end


// =========================================================================
// Production function parameter table
// =========================================================================

program define _pte_display_prodfunc
    version 14.0
    syntax [, Level(cilevel) BYGROUPLIVE]
    
    // Section title
    di as text _n "{hline 78}"
    di as text " Production Function Parameters"
    di as text "{hline 78}"

    if "`bygrouplive'" != "" {
        capture confirm matrix e(b_by)
        if _rc == 0 {
            tempname b_by
            matrix `b_by' = e(b_by)
            di as text " Grouped point-estimate coefficients (rows=groups):"
            matrix list `b_by'
        }
        else {
            capture confirm matrix e(beta_boot_g1)
            if _rc == 0 {
                di as text " Grouped bootstrap coefficient draws are stored in e(beta_boot_g#)."
                di as text " Inspect e(beta_boot_g#) and e(beta_se_g#) for coefficient summaries."
            }
        }
    }
    else {
        capture confirm matrix e(bs_betas)
        if _rc == 0 {
            tempname bs_betas
            matrix `bs_betas' = e(bs_betas)
            local bs_beta_cols : colnames `bs_betas'
            di as text " Bootstrap coefficient draws are stored in e(bs_betas)."
            if `"`bs_beta_cols'"' != "" {
                di as text " Columns: `bs_beta_cols'"
            }
        }
        capture confirm matrix e(beta_controls)
        if _rc == 0 {
            tempname beta_controls
            matrix `beta_controls' = e(beta_controls)
            local beta_control_cols : colnames `beta_controls'
            local beta_control_count = colsof(`beta_controls')
            di as text " Point control coefficients are stored in e(beta_controls)."
            if `"`beta_control_cols'"' != "" {
                di as text " Control columns: `beta_control_cols'"
            }
            if `beta_control_count' == 1 {
                capture scalar _pte_beta_t_alias = e(beta_t)
                if _rc == 0 {
                    di as text " Single-control alias is reposted in e(beta_t)."
                    capture scalar drop _pte_beta_t_alias
                }
            }
        }
    }
    
    // Use ereturn display only when both e(b) and e(V) exist.
    // Otherwise fall back to scalar returns so commands that intentionally
    // omit e(V) do not fail during display.
    capture confirm matrix e(b)
    local has_b = (_rc == 0)
    capture confirm matrix e(V)
    local has_V = (_rc == 0)
    if `has_b' & `has_V' {
        ereturn display, level(`level')
    }
    else {
        // Fallback: display from scalar returns
        local pfunc = "`e(pfunc)'"
        capture local bl = e(beta_l)
        capture local bk = e(beta_k)
        if !missing(`bl') {
            di as text _col(5) "beta_l" _col(20) "=" _col(22) as result %12.6f `bl'
        }
        if !missing(`bk') {
            di as text _col(5) "beta_k" _col(20) "=" _col(22) as result %12.6f `bk'
        }
        if "`pfunc'" == "translog" {
            capture local bll = e(beta_ll)
            capture local bkk = e(beta_kk)
            capture local blk = e(beta_lk)
            if !missing(`bll') {
                di as text _col(5) "beta_ll" _col(20) "=" _col(22) as result %12.6f `bll'
            }
            if !missing(`bkk') {
                di as text _col(5) "beta_kk" _col(20) "=" _col(22) as result %12.6f `bkk'
            }
            if !missing(`blk') {
                di as text _col(5) "beta_lk" _col(20) "=" _col(22) as result %12.6f `blk'
            }
        }
    }
    
    // GMM diagnostics
    di as text "{hline 78}"
    
    // GMM sample size
    capture local ngmm = e(N_gmm)
    if _rc == 0 & !missing(`ngmm') {
        di as text "GMM sample size" _col(25) "=" _col(27) as result %10.0fc `ngmm'
    }
    
    // GMM iterations
    capture local niter = e(iterations)
    if _rc == 0 & !missing(`niter') {
        di as text "GMM iterations" _col(25) "=" _col(27) as result %5.0f `niter'
    }
    
    // GMM criterion (objective function value)
    capture local fval = e(fval)
    if _rc == 0 & !missing(`fval') {
        di as text "GMM criterion" _col(25) "=" _col(27) as result %12.7f `fval'
    }
    
    // Convergence status
    capture local conv = e(converged)
    if _rc == 0 & !missing(`conv') {
        if `conv' == 1 {
            di as text "Convergence" _col(25) "=" _col(27) as result "achieved"
        }
        else {
            di as text "Convergence" _col(25) "=" _col(27) as error "NOT achieved"
        }
    }
    
    // Wald test for CRS (Translog only, if available)
    capture local waldstat = e(waldtest_rts)
    if _rc == 0 & !missing(`waldstat') {
        capture local waldp = e(waldtest_rts_p)
        if _rc == 0 & !missing(`waldp') {
            di as text "Wald test (CRS)" _col(25) "=" _col(27) ///
                as result %8.3f `waldstat' as text " (p = " as result %6.4f `waldp' as text ")"
        }
    }
end



// =========================================================================
// Evolution parameter table
// =========================================================================

program define _pte_display_evolution
    version 14.0
    syntax [, BYGROUPLIVE]

    local p = e(omegapoly)
    
    // Section title
    di as text _n "{hline 78}"
    di as text " Evolution Parameters (omegapoly=`p')"
    di as text "{hline 78}"

    if "`bygrouplive'" != "" {
        capture confirm matrix e(rho_by)
        if _rc == 0 {
            tempname rho_by
            matrix `rho_by' = e(rho_by)
            di as text " Grouped untreated-law coefficients (rows=groups):"
            matrix list `rho_by'
            capture confirm matrix e(sigma_by)
            if _rc == 0 {
                tempname sigma_by
                matrix `sigma_by' = e(sigma_by)
                di as text " Grouped sigma(eps0) estimates:"
                matrix list `sigma_by'
            }
            di as text "{hline 78}"
            di as text " Note: rows correspond to group order stored in e(groups)."
            exit
        }
        capture confirm matrix e(rho_0)
        if _rc != 0 {
            di as text " Grouped bootstrap replay does not publish per-group evolution matrices"
            di as text " in the current e() bundle."
            capture local sig_trim = e(sigma_eps_trim)
            if _rc == 0 & !missing(`sig_trim') {
                di as text " sigma(eps0) trimmed" _col(25) "=" _col(27) as result %9.6f `sig_trim'
            }
            capture local sig_raw = e(sigma_eps)
            if _rc == 0 & !missing(`sig_raw') {
                di as text " sigma(eps0) raw" _col(25) "=" _col(27) as result %9.6f `sig_raw'
            }
            di as text "{hline 78}"
            di as text " Note: grouped ATT below is replayed from stored e() results."
            exit
        }
    }
    
    // Table header with h_bar_0 and h_bar_1 columns
    // Use Unicode if available, ASCII fallback
    _pte_unicode_or_ascii "h{c -}{c 772}{c 8320} (D=0)" "h0 (D=0)"
    local h0_label = "`s(result)'"
    _pte_unicode_or_ascii "h{c -}{c 772}{c 8321} (D=1)" "h1 (D=1)"
    local h1_label = "`s(result)'"
    
    di as text _col(5) "Parameter" _col(22) "`h0_label'" _col(40) "`h1_label'" _col(58) "Usage"
    di as text "{hline 78}"
    
    // Get rho_0 and rho_1 matrices
    tempname rho0_mat rho1_mat
    matrix `rho0_mat' = e(rho_0)
    local has_rho1 = 0
    capture confirm matrix e(rho_1)
    if _rc == 0 {
        matrix `rho1_mat' = e(rho_1)
        local has_rho1 = 1
    }
    else {
        matrix `rho1_mat' = J(1, `p' + 1, .)
        matrix colnames `rho1_mat' = colnames(`rho0_mat')
    }
    
    // Row labels
    local rowlbl_0 "constant"
    local rowlbl_1 "omega"
    local rowlbl_2 "omega^2"
    local rowlbl_3 "omega^3"
    local rowlbl_4 "omega^4"
    
    // Display rho coefficients (used for simulation)
    forvalues j = 0/`p' {
        local rho_j = el(`rho0_mat', 1, `j'+1)
        local eff_j = el(`rho1_mat', 1, `j'+1)
        local lbl = "`rowlbl_`j''"
        
        di as text _col(5) "`lbl'" ///
            _col(20) as result %12.6f `rho_j' ///
            _col(38) as result %12.6f `eff_j' ///
            _col(56) as text "simulation"
    }
    
    di as text "{hline 78}"
    
    // Compact gamma/delta diagnostics section
    di as text " Raw interaction terms (diagnostics):"
    if `has_rho1' {
        // gamma coefficients on one line
        local gamma_line ""
        forvalues j = 1/`p' {
            capture local gj = e(gamma`j')
            if _rc == 0 & !missing(`gj') {
                if `j' > 1 local gamma_line "`gamma_line', "
                local gamma_line "`gamma_line'gamma`j'="
                local gamma_line "`gamma_line'`=string(`gj', "%9.6f")'"
            }
        }
        if "`gamma_line'" != "" {
            di as text _col(5) "`gamma_line'"
        }
        
        // delta on separate line
        capture local dval = e(delta)
        if _rc == 0 & !missing(`dval') {
            di as text _col(5) "delta=" as result %9.6f `dval'
        }
    }
    else {
        di as text _col(5) "h1 not identified (h0 only: no treated-lag support)"
    }
    
    di as text "{hline 78}"
    
    // Epsilon-0 statistics
    _pte_unicode_or_ascii "sigma(eps0)" "sigma(eps0)"
    local sig_label = "`s(result)'"
    
    capture local sig_trim = e(sigma_eps_trim)
    capture local sig_raw = e(sigma_eps)
    
    if !missing(`sig_trim') {
        di as text " `sig_label' trimmed" _col(25) "=" _col(27) as result %9.6f `sig_trim'
    }
    if !missing(`sig_raw') {
        di as text " `sig_label' raw" _col(25) "=" _col(27) as result %9.6f `sig_raw'
    }
    
    // Keep the sample labels aligned with the posted count semantics:
    // eps0 is a filtered untreated pre-treatment innovation pool, not the
    // broader evolution-regression sample.
    capture local eps0_n = e(N_eps0)
    if _rc == 0 & !missing(`eps0_n') {
        di as text " N(eps0 sample)" _col(25) "=" _col(27) as result %10.0fc `eps0_n'
    }
    else {
        capture local evo_n = e(N_evo)
        if _rc == 0 & !missing(`evo_n') {
            di as text " N(evolution sample)" _col(25) "=" _col(27) as result %10.0fc `evo_n'
        }
    }
    
    // Footnote
    di as text "{hline 78}"
    di as text " Note: h0 = rho polynomial (counterfactual simulation)"
    if `has_rho1' {
        di as text "       h1 = (rho+gamma/delta) polynomial (treated evolution)"
    }
    else {
        di as text "       h0 only: treated-lag support is absent, so h1 is not identified."
    }
    di as text "       Significance: * p<0.10, ** p<0.05, *** p<0.01 (two-tailed)"
end


// =========================================================================
// ATT results table
// =========================================================================

program define _pte_display_att
    version 14.0
    syntax [, Level(cilevel)]
    
    // Section title
    di as text _n "{hline 78}"
    di as text " Average Treatment Effects on the Treated (ATT)"
    di as text "{hline 78}"
    
    // Get ATT table matrix (nperiods x 5: nt ATT sd N se)
    // Source: e(att_table) for point estimate. In bootstrap replay, prefer the
    // canonical trimmed table when it exists so the displayed ATT track stays
    // aligned with e(att_se) / e(att_ci_*); fall back to the raw table only
    // when trimming was not active.
    tempname att_mat
    local using_bootstrap_table = 0
    local using_trimmed_track = 0
    capture confirm matrix e(result_table_trim)
    if _rc == 0 {
        matrix `att_mat' = e(result_table_trim)
        local using_bootstrap_table = 1
        local using_trimmed_track = 1
    }
    else {
        capture confirm matrix e(result_table_raw)
        if _rc == 0 {
            matrix `att_mat' = e(result_table_raw)
            local using_bootstrap_table = 1
        }
        else {
            capture confirm matrix e(att_table)
            if _rc != 0 {
                di as error "_pte_display: no ATT table found"
                exit 301
            }
            matrix `att_mat' = e(att_table)
        }
    }
    local nrows = rowsof(`att_mat')
    local ncols = colsof(`att_mat')
    local n_col = 4
    if `using_bootstrap_table' & `ncols' >= 7 {
        local n_col = 7
    }
    local display_rows = `nrows'
    local has_overall_row = 0
    if `using_bootstrap_table' {
        local last_nt = el(`att_mat', `nrows', 1)
        if !missing(`last_nt') & `last_nt' < 0 {
            local has_overall_row = 1
            local display_rows = `nrows' - 1
        }
    }

    // Bootstrap replay publishes period sample counts separately because
    // result_table_raw col 7 is N_valid (successful bootstrap draws), not N.
    local has_display_n = 0
    if `using_bootstrap_table' {
        capture confirm matrix e(N_by_period)
        if _rc == 0 {
            tempname n_by_mat
            matrix `n_by_mat' = e(N_by_period)
            local n_by_rows = rowsof(`n_by_mat')
            local n_by_cols = colsof(`n_by_mat')
            if (`n_by_rows' == 1 & `n_by_cols' >= `display_rows') | ///
                (`n_by_cols' == 1 & `n_by_rows' >= `display_rows') {
                local has_display_n = 1
            }
        }
    }
    
    // Dynamic ATT point paths keep e(att_se) as descriptive sample
    // dispersion, but only bootstrap inference should drive public ATT
    // uncertainty columns in replay/display.
    local bootstrap_reps = .
    capture local bootstrap_reps = e(bootstrap)
    if _rc != 0 | missing(`bootstrap_reps') {
        capture local bootstrap_reps = e(breps)
    }
    if _rc != 0 | missing(`bootstrap_reps') {
        capture local bootstrap_reps = e(nboot)
    }

    // Check if bootstrap SE exists
    local has_se = 0
    if !missing(`bootstrap_reps') & `bootstrap_reps' > 0 {
        capture confirm matrix e(att_se)
        if _rc == 0 {
            local has_se = 1
            tempname se_mat
            matrix `se_mat' = e(att_se)
        }
    }
    
    // Check if CI exists
    local has_ci = 0
    capture confirm matrix e(att_ci_lower)
    if _rc == 0 {
        capture confirm matrix e(att_ci_upper)
        if _rc == 0 {
            local has_ci = 1
            tempname ci_lo_mat ci_hi_mat
            matrix `ci_lo_mat' = e(att_ci_lower)
            matrix `ci_hi_mat' = e(att_ci_upper)
        }
    }
    local use_stored_ci = `has_ci'
    local stored_level = .
    capture local stored_level = e(level)
    if _rc == 0 & !missing(`stored_level') {
        if abs(`stored_level' - `level') > 1e-8 {
            local use_stored_ci = 0
        }
    }
    
    // Table header
    if `has_se' {
        di as text " Period" _col(14) "ATT" _col(28) "Std. Err." ///
            _col(42) "[`level'% Conf. Interval]" _col(68) "N"
    }
    else {
        di as text " Period" _col(14) "ATT" _col(42) "{c -}" _col(68) "N"
    }
    di as text "{hline 78}"
    
    // z critical value for CI fallback calculation
    local z_crit = invnormal(1 - (100 - `level') / 200)
    local n_total_display = 0
    
    // Display each period row
    // att_table format: [nt, ATT, sd, N, se] — all rows are period rows
    forvalues i = 1/`display_rows' {
        local ell = el(`att_mat', `i', 1)
        local att_val = el(`att_mat', `i', 2)
        local n_obs = el(`att_mat', `i', `n_col')
        if `has_display_n' {
            if `n_by_rows' == 1 {
                local n_obs = el(`n_by_mat', 1, `i')
            }
            else {
                local n_obs = el(`n_by_mat', `i', 1)
            }
        }
        if !missing(`n_obs') {
            local n_total_display = `n_total_display' + `n_obs'
        }
        
        // Handle missing ATT
        if missing(`att_val') {
            di as text %6.0f `ell' _col(12) as text "."
            continue
        }
        
        // Get SE from att_table col 5 or att_se matrix
        local se_val = .
        if `has_se' {
            local se_rows = rowsof(`se_mat')
            local se_cols = colsof(`se_mat')
            if `se_rows' == 1 & `se_cols' >= `i' {
                local se_val = el(`se_mat', 1, `i')
            }
            else if `se_cols' == 1 & `se_rows' >= `i' {
                local se_val = el(`se_mat', `i', 1)
            }
        }
        else if `ncols' >= 5 {
            local se_val = el(`att_mat', `i', 5)
        }
        
        // Calculate significance
        local sig ""
        if !missing(`se_val') & `se_val' > 0 {
            local t_stat = abs(`att_val' / `se_val')
            if `t_stat' > 2.576 {
                local sig "***"
            }
            else if `t_stat' > 1.960 {
                local sig "**"
            }
            else if `t_stat' > 1.645 {
                local sig "*"
            }
        }
        
        // Get or compute CI
        local ci_lo = .
        local ci_hi = .
        if `use_stored_ci' {
            local ci_lo_rows = rowsof(`ci_lo_mat')
            local ci_lo_cols = colsof(`ci_lo_mat')
            local ci_hi_rows = rowsof(`ci_hi_mat')
            local ci_hi_cols = colsof(`ci_hi_mat')
            if `ci_lo_rows' == 1 & `ci_lo_cols' >= `i' {
                local ci_lo = el(`ci_lo_mat', 1, `i')
            }
            else if `ci_lo_cols' == 1 & `ci_lo_rows' >= `i' {
                local ci_lo = el(`ci_lo_mat', `i', 1)
            }
            if `ci_hi_rows' == 1 & `ci_hi_cols' >= `i' {
                local ci_hi = el(`ci_hi_mat', 1, `i')
            }
            else if `ci_hi_cols' == 1 & `ci_hi_rows' >= `i' {
                local ci_hi = el(`ci_hi_mat', `i', 1)
            }
        }
        else if `has_se' & !missing(`se_val') {
            // A degenerate bootstrap distribution still implies a valid
            // point-mass interval, not missing bounds.
            if `se_val' == 0 {
                local ci_lo = `att_val'
                local ci_hi = `att_val'
            }
            else if `se_val' > 0 {
                // Fallback: compute CI from ATT +/- z * SE
                local ci_lo = `att_val' - `z_crit' * `se_val'
                local ci_hi = `att_val' + `z_crit' * `se_val'
            }
        }
        
        // Display row
        if `has_se' & !missing(`se_val') {
            di as text %6.0f `ell' ///
                _col(10) as result %10.4f `att_val' as text "`sig'" ///
                _col(26) as text "(" as result %7.4f `se_val' as text ")" ///
                _col(40) as text "[" as result %8.4f `ci_lo' ///
                as text ", " as result %8.4f `ci_hi' as text "]" ///
                _col(66) as result %8.0f `n_obs'
        }
        else {
            di as text %6.0f `ell' ///
                _col(10) as result %10.4f `att_val' ///
                _col(26) as text "{c -}" ///
                _col(66) as result %8.0f `n_obs'
        }
    }
    
    // Total row — period rows and total-row objects must come from the same
    // public ATT track. Canonical trimmed replay uses the trimmed overall ATT
    // bundle; raw/point replay uses the standard overall ATT objects.
    di as text "{hline 78}"
    local att_total = .
    if `using_trimmed_track' {
        capture local att_total = e(ATT_avg_trim)
        if _rc != 0 | missing(`att_total') {
            capture local att_total = e(att_trim)
        }
    }
    else {
        capture local att_total = e(ATT_avg)
        if _rc != 0 | missing(`att_total') {
            capture local att_total = e(att)
        }
    }
    if _rc != 0 | missing(`att_total') {
        if `using_bootstrap_table' & `has_overall_row' {
            local att_total = el(`att_mat', `nrows', 2)
        }
    }
    if _rc != 0 | missing(`att_total') {
        if `using_trimmed_track' {
            di as error "pte replay requires e(ATT_avg_trim)"
        }
        else {
            di as error "pte replay requires e(ATT_avg)"
        }
        exit 301
    }
    if `has_display_n' {
        local n_total = `n_total_display'
    }
    else if _rc == 0 & !missing(`att_total') {
        // Compute total N from period rows unless the bootstrap replay table
        // already carries an overall sentinel row (nt < 0).
        if `has_overall_row' {
            local n_total = el(`att_mat', `nrows', `n_col')
        }
        else {
            local n_total = 0
            forvalues i = 1/`display_rows' {
                local _n = el(`att_mat', `i', `n_col')
                if !missing(`_n') {
                    local n_total = `n_total' + `_n'
                }
            }
        }
    }
    
    // Total SE from bootstrap
    local se_total = .
    if `has_se' {
        local se_nrows = rowsof(`se_mat')
        local se_ncols = colsof(`se_mat')
        if `se_nrows' == 1 & `se_ncols' > `display_rows' {
            local se_total = el(`se_mat', 1, `display_rows' + 1)
        }
        else if `se_ncols' == 1 & `se_nrows' > `display_rows' {
            local se_total = el(`se_mat', `display_rows' + 1, 1)
        }
    }
    if `using_trimmed_track' {
        capture {
            local _bs_se = e(bs_se_trim)
            if !missing(`_bs_se') local se_total = `_bs_se'
        }
    }
    else {
        capture {
            local _bs_se = e(bs_se)
            if !missing(`_bs_se') local se_total = `_bs_se'
        }
    }
    if missing(`se_total') & `using_bootstrap_table' & `has_overall_row' & `ncols' >= 3 {
        local se_total = el(`att_mat', `nrows', 3)
    }
    
    // Total significance
    local sig_total ""
    if !missing(`se_total') & `se_total' > 0 {
        local t_total = abs(`att_total' / `se_total')
        if `t_total' > 2.576 local sig_total "***"
        else if `t_total' > 1.960 local sig_total "**"
        else if `t_total' > 1.645 local sig_total "*"
    }
    
    // Total CI from bootstrap scalars
    local ci_lo_total = .
    local ci_hi_total = .
    if `using_trimmed_track' & `use_stored_ci' {
        capture {
            local ci_lo_total = e(ci_lo_trim)
        }
        capture {
            local ci_hi_total = e(ci_hi_trim)
        }
    }
    else if `use_stored_ci' {
        capture {
            local ci_lo_total = e(ci_lo)
        }
        capture {
            local ci_hi_total = e(ci_hi)
        }
    }
    // The bootstrap overall sentinel row stores level-specific bounds. Reuse
    // it only when replay is still operating at the stored CI level.
    if `use_stored_ci' & missing(`ci_lo_total') & `using_bootstrap_table' & `has_overall_row' & `ncols' >= 5 {
        local ci_lo_total = el(`att_mat', `nrows', 4)
    }
    if `use_stored_ci' & missing(`ci_hi_total') & `using_bootstrap_table' & `has_overall_row' & `ncols' >= 5 {
        local ci_hi_total = el(`att_mat', `nrows', 5)
    }
    if missing(`ci_lo_total') & !missing(`se_total') {
        if `se_total' == 0 {
            local ci_lo_total = `att_total'
            local ci_hi_total = `att_total'
        }
        else if `se_total' > 0 {
            local ci_lo_total = `att_total' - `z_crit' * `se_total'
            local ci_hi_total = `att_total' + `z_crit' * `se_total'
        }
    }
    
    if `has_se' & !missing(`se_total') {
        di as text " Total" ///
            _col(10) as result %10.4f `att_total' as text "`sig_total'" ///
            _col(26) as text "(" as result %7.4f `se_total' as text ")" ///
            _col(40) as text "[" as result %8.4f `ci_lo_total' ///
            as text ", " as result %8.4f `ci_hi_total' as text "]" ///
            _col(66) as result %8.0f `n_total'
    }
    else {
        di as text " Total" ///
            _col(10) as result %10.4f `att_total' ///
            _col(26) as text "{c -}" ///
            _col(66) as result %8.0f `n_total'
    }
    
    di as text "{hline 78}"
    
    // Bootstrap and simulation info
    capture local nboot = e(bootstrap)
    if _rc != 0 | missing(`nboot') {
        capture local nboot = e(breps)
    }
    if _rc != 0 | missing(`nboot') {
        capture local nboot = e(nboot)
    }
    if _rc == 0 & !missing(`nboot') & `nboot' > 0 {
        di as text " Bootstrap replications" _col(30) "=" ///
            _col(32) as result %5.0f `nboot'
    }
    
    capture local nsim_val = e(nsim)
    if _rc == 0 & !missing(`nsim_val') {
        di as text " Simulation paths (M)" _col(30) "=" ///
            _col(32) as result %5.0f `nsim_val'
    }
    
    di as text " Confidence level" _col(30) "=" ///
        _col(32) as result "`level'%"
    
    capture local point_seed = e(point_seed)
    local has_point_seed = (_rc == 0 & !missing(`point_seed'))
    capture local inner_seed = e(inner_seed)
    local has_inner_seed = (_rc == 0 & !missing(`inner_seed'))
    capture local seed_outer = e(seed_outer)
    local has_seed_outer = (_rc == 0 & !missing(`seed_outer'))
    capture local seed_val = e(seed)
    local has_seed = (_rc == 0 & !missing(`seed_val'))
    local point_seed_txt ""
    local inner_seed_txt ""
    local seed_outer_txt ""
    if `has_point_seed' {
        local point_seed_txt = trim(string(`point_seed', "%21.0f"))
    }
    if `has_inner_seed' {
        local inner_seed_txt = trim(string(`inner_seed', "%21.0f"))
    }
    if `has_seed_outer' {
        local seed_outer_txt = trim(string(`seed_outer', "%21.0f"))
    }

    // e(seed) stores wrapper/bootstrap metadata, while e(point_seed) stores
    // the realized ATT simulation seed on paths that reset the inner RNG.
    if `has_point_seed' {
        di as text " ATT simulation seed:  " as result "`point_seed_txt'" as text " (fixed)"
    }
    else if `has_inner_seed' {
        di as text " ATT simulation seed:  " as result "`inner_seed_txt'" as text " (fixed)"
    }
    if `has_seed_outer' {
        di as text " Outer bootstrap seed: " as result "`seed_outer_txt'"
    }
    if !`has_point_seed' & !`has_inner_seed' & !`has_seed_outer' & `has_seed' {
        di as text " Seed" _col(30) "=" ///
            _col(32) as result %10.0f `seed_val'
    }
    
    // Significance footnote
    di as text " Significance: * p<0.10, ** p<0.05, *** p<0.01 (two-tailed)"
end


// =========================================================================
// No-ATT message display
// =========================================================================

program define _pte_display_noatt_msg
    version 14.0
    
    di as text _n "{hline 78}"
    di as text " ATT Estimation: Skipped (noatt option specified)"
    di as text "{hline 78}"
    di as text " Note: Use pte without noatt option to estimate treatment effects."
    di as text "{hline 78}"
end


// =========================================================================
// By-group display (Table 2 style summary)
// =========================================================================

program define _pte_display_bygroup
    version 14.0
    syntax, BY(string) Level(cilevel) [NOAtt AGGregate]

    // Prefer the live bygroup worker contracts. Keep the older
    // att_table/att_bygroup path below as a compatibility fallback.
    local has_live_point = 0
    capture confirm matrix e(att_by)
    if _rc == 0 local has_live_point = 1
    local has_live_boot = 0
    capture confirm matrix e(att_mean_pool)
    if _rc == 0 local has_live_boot = 1

    if `has_live_point' | `has_live_boot' {
        local groups `"`e(groups)'"'
        if `"`groups'"' == "." {
            local groups ""
        }
        if `"`groups'"' == "" {
            di as error "_pte_display: grouped replay requires e(groups)"
            exit 301
        }
        local has_point_surface = 0
        local n_groups = .
        capture local n_groups = e(n_groups)
        if _rc != 0 | missing(`n_groups') {
            capture local n_groups = e(ngroups)
        }
        if _rc != 0 | missing(`n_groups') {
            local n_groups = 0
        }

        local attperiods = .
        local nperiods = .
        local periodlist ""

        if `has_live_point' {
            tempname att_by att_pool
            matrix `att_by' = e(att_by)
            capture confirm matrix e(att_pool)
            if _rc != 0 {
                di as error "pte replay requires e(att_pool)"
                exit 301
            }
            matrix `att_pool' = e(att_pool)
            if `n_groups' <= 0 {
                local n_groups = rowsof(`att_by')
            }
        }
        else {
            tempname att_mean_pool
            matrix `att_mean_pool' = e(att_mean_pool)
            local has_point_surface = 0
            capture confirm matrix e(att_by_point)
            if _rc == 0 {
                tempname att_by_point
                matrix `att_by_point' = e(att_by_point)
                local point_rows = rowsof(`att_by_point')
                local point_cols = colsof(`att_by_point')
                if `point_cols' >= 2 {
                    local has_point_surface = 1
                    if `n_groups' <= 0 {
                        local n_groups = `point_rows'
                    }
                }
            }
            if `n_groups' <= 0 {
                local n_groups = 0
                forvalues _g = 1/999 {
                    capture confirm matrix e(att_boot_g`_g')
                    if _rc != 0 continue, break
                    local n_groups = `_g'
                }
            }
            local nperiods = colsof(`att_mean_pool') - 1
            if `has_point_surface' {
                local expected_point_cols = `nperiods' + 1
                if `point_cols' != `expected_point_cols' {
                    local has_point_surface = 0
                }
                else if `n_groups' > 0 & `point_rows' != `n_groups' {
                    // e(att_by_point) is a full by-group point surface. If it
                    // covers only part of e(groups), replay must fail rather
                    // than mix point rows with bootstrap-mean rows.
                    di as error "_pte_display: e(att_by_point) row count does not match grouped replay metadata"
                    di as error "  rowsof(e(att_by_point)) = `point_rows', groups = `n_groups'"
                    exit 503
                }
            }
        }

        local dyncols = .
        if `has_live_point' {
            local dyncols = colsof(`att_by') - 1
        }
        else if `has_point_surface' {
            local dyncols = `point_cols' - 1
        }
        else {
            local dyncols = colsof(`att_mean_pool') - 1
        }

        capture confirm matrix e(attperiods)
        if _rc == 0 {
            tempname attperiods_mat
            matrix `attperiods_mat' = e(attperiods)
            quietly _pte_attperiods_support `attperiods_mat' `dyncols' ///
                "_pte_display grouped replay"
            local nperiods = r(nperiods)
            local periodlist `"`r(periodlist)'"'
        }
        else {
            capture local attperiods = e(attperiods_max)
            if _rc != 0 | missing(`attperiods') {
                capture local attperiods = e(attperiods)
            }
            if _rc != 0 | missing(`attperiods') {
                local attperiods = `dyncols' - 1
            }
            local nperiods = `attperiods' + 1
            forvalues _idx = 1/`nperiods' {
                local period_token = `_idx' - 1
                local periodlist "`periodlist' `period_token'"
            }
            local periodlist : list retokenize periodlist
        }
        local avg_col = `nperiods' + 1

        forvalues _g = 1/`n_groups' {
            local grp_label_`_g' ""
        }
        local _g = 0
        local groups_work `"`groups'"'
        while `"`groups_work'"' != "" {
            gettoken grp groups_work : groups_work, quotes
            if `"`grp'"' == "" {
                continue
            }
            local ++_g
            if `_g' > `n_groups' {
                di as error "_pte_display: e(groups) has more entries than grouped ATT rows"
                di as error "  groups parsed = `_g', grouped rows = `n_groups'"
                exit 503
            }
            local grp_label `"`grp'"'
            local grp_len = strlen(`"`grp_label'"')
            if `grp_len' >= 2 & ///
                substr(`"`grp_label'"', 1, 1) == char(34) & ///
                substr(`"`grp_label'"', `grp_len', 1) == char(34) {
                local grp_label = substr(`"`grp_label'"', 2, `grp_len' - 2)
            }
            local grp_label_`_g' `"`grp_label'"'
        }
        if `_g' != `n_groups' {
            di as error "_pte_display: e(groups) count does not match grouped ATT rows"
            di as error "  groups parsed = `_g', grouped rows = `n_groups'"
            exit 503
        }

        local use_trim_boot = 0
        if !`has_live_point' & "`e(notrimeps)'" == "" {
            capture confirm matrix e(att_mean_pool_trim)
            if _rc == 0 {
                capture confirm matrix e(att_se_pool_trim)
                if _rc == 0 {
                    capture confirm matrix e(att_ci_lower_trim)
                    if _rc == 0 {
                        capture confirm matrix e(att_ci_upper_trim)
                        if _rc == 0 {
                            local use_trim_boot = 1
                        }
                    }
                }
            }
        }

        // Grouped bootstrap replay is a bundle contract: once e(groups) says
        // how many groups exist, each group must publish the corresponding
        // ATT draw matrix. Reject partial bundles explicitly before rendering.
        if !`has_live_point' & !`has_point_surface' {
            forvalues _g = 1/`n_groups' {
                local _has_group_draw = 0
                if `use_trim_boot' {
                    capture confirm matrix e(att_trim_boot_g`_g')
                    if _rc == 0 {
                        local _has_group_draw = 1
                    }
                }
                if !`_has_group_draw' {
                    capture confirm matrix e(att_boot_g`_g')
                    if _rc == 0 {
                        local _has_group_draw = 1
                    }
                }
                if !`_has_group_draw' {
                    di as error "_pte_display: missing e(att_boot_g`_g') for grouped replay"
                    di as error "  grouped bootstrap replay requires one ATT draw matrix per group in e(groups)"
                    exit 301
                }
            }
        }

        di as text _n "{hline 78}"
        di as text " Results by: `by'"
        di as text "{hline 78}"

        di as text %-12s "`by'" _continue
        forvalues _idx = 1/`nperiods' {
            local period_token : word `_idx' of `periodlist'
            di as text %12s "ATT_`period_token'" _continue
        }
        di as text %12s "ATT_avg"
        di as text "{hline 78}"

        forvalues g = 1/`n_groups' {
            local grp_label_name "grp_label_`g'"
            local glabel "``grp_label_name''"
            local rowline `"`glabel'"'
            if `has_live_point' {
                forvalues _idx = 1/`nperiods' {
                    local _col = `_idx'
                    local _att_val = el(`att_by', `g', `_col')
                    local rowcell : display %12.4f `_att_val'
                    local rowline `"`rowline'`rowcell'"'
                }
                local _att_avg_val = el(`att_by', `g', `avg_col')
                local rowcell : display %12.4f `_att_avg_val'
                local rowline `"`rowline'`rowcell'"'
            }
            else {
                if `has_point_surface' {
                    if `g' <= rowsof(`att_by_point') {
                        forvalues _idx = 1/`nperiods' {
                            local _col = `_idx'
                            local _att_val = el(`att_by_point', `g', `_col')
                            local rowcell : display %12.4f `_att_val'
                            local rowline `"`rowline'`rowcell'"'
                        }
                        local _att_avg_val = el(`att_by_point', `g', `avg_col')
                        local rowcell : display %12.4f `_att_avg_val'
                        local rowline `"`rowline'`rowcell'"'
                    }
                    else {
                        tempname att_boot_g
                        if `use_trim_boot' {
                            capture confirm matrix e(att_trim_boot_g`g')
                            if _rc == 0 {
                                matrix `att_boot_g' = e(att_trim_boot_g`g')
                            }
                            else {
                                matrix `att_boot_g' = e(att_boot_g`g')
                            }
                        }
                        else {
                            matrix `att_boot_g' = e(att_boot_g`g')
                        }
                        local _nboot_rows = rowsof(`att_boot_g')
                        forvalues _idx = 1/`nperiods' {
                            local _src = `_idx'
                            local _sum = 0
                            local _n = 0
                            forvalues _r = 1/`_nboot_rows' {
                                local _val = el(`att_boot_g', `_r', `_src')
                                if !missing(`_val') {
                                    local _sum = `_sum' + `_val'
                                    local _n = `_n' + 1
                                }
                            }
                            local _mean = .
                            if `_n' > 0 {
                                local _mean = `_sum' / `_n'
                            }
                            local rowcell : display %12.4f `_mean'
                            local rowline `"`rowline'`rowcell'"'
                        }
                        local _sum = 0
                        local _n = 0
                        forvalues _r = 1/`_nboot_rows' {
                            local _val = el(`att_boot_g', `_r', `avg_col')
                            if !missing(`_val') {
                                local _sum = `_sum' + `_val'
                                local _n = `_n' + 1
                            }
                        }
                        local _mean = .
                        if `_n' > 0 {
                            local _mean = `_sum' / `_n'
                        }
                        local rowcell : display %12.4f `_mean'
                        local rowline `"`rowline'`rowcell'"'
                    }
                }
                else {
                    tempname att_boot_g
                    if `use_trim_boot' {
                        capture confirm matrix e(att_trim_boot_g`g')
                        if _rc == 0 {
                            matrix `att_boot_g' = e(att_trim_boot_g`g')
                        }
                        else {
                            matrix `att_boot_g' = e(att_boot_g`g')
                        }
                    }
                    else {
                        matrix `att_boot_g' = e(att_boot_g`g')
                    }
                    local _nboot_rows = rowsof(`att_boot_g')
                    forvalues _idx = 1/`nperiods' {
                        local _src = `_idx'
                        local _sum = 0
                        local _n = 0
                        forvalues _r = 1/`_nboot_rows' {
                            local _val = el(`att_boot_g', `_r', `_src')
                            if !missing(`_val') {
                                local _sum = `_sum' + `_val'
                                local _n = `_n' + 1
                            }
                        }
                        local _mean = .
                        if `_n' > 0 {
                            local _mean = `_sum' / `_n'
                        }
                        local rowcell : display %12.4f `_mean'
                        local rowline `"`rowline'`rowcell'"'
                    }
                    local _sum = 0
                    local _n = 0
                    forvalues _r = 1/`_nboot_rows' {
                        local _val = el(`att_boot_g', `_r', `avg_col')
                        if !missing(`_val') {
                            local _sum = `_sum' + `_val'
                            local _n = `_n' + 1
                        }
                    }
                    local _mean = .
                    if `_n' > 0 {
                        local _mean = `_sum' / `_n'
                    }
                    local rowcell : display %12.4f `_mean'
                    local rowline `"`rowline'`rowcell'"'
                }
            }
            di as text `"`rowline'"'
        }

        di as text "{hline 78}"
        local rowline "Pooled"
        if `has_live_point' {
            forvalues _idx = 1/`nperiods' {
                local _col = `_idx'
                local _att_pool_val = el(`att_pool', 1, `_col')
                local rowcell : display %12.4f `_att_pool_val'
                local rowline `"`rowline'`rowcell'"'
            }
            local _att_pool_avg = el(`att_pool', 1, `avg_col')
            local rowcell : display %12.4f `_att_pool_avg'
            local rowline `"`rowline'`rowcell'"'
        }
        else {
            if `use_trim_boot' {
                matrix `att_mean_pool' = e(att_mean_pool_trim)
            }
            forvalues _idx = 1/`nperiods' {
                local _src = `_idx'
                local _att_pool_val = el(`att_mean_pool', 1, `_src')
                local rowcell : display %12.4f `_att_pool_val'
                local rowline `"`rowline'`rowcell'"'
            }
            local _att_pool_avg = el(`att_mean_pool', 1, `avg_col')
            local rowcell : display %12.4f `_att_pool_avg'
            local rowline `"`rowline'`rowcell'"'
        }
        di as text `"`rowline'"'

        capture confirm matrix e(att_se_pool)
        if _rc == 0 {
            tempname att_se_pool
            matrix `att_se_pool' = e(att_se_pool)
            if !`has_live_point' & `use_trim_boot' {
                matrix `att_se_pool' = e(att_se_pool_trim)
            }
            local rowline "  (SE)"
            if `has_live_point' {
                forvalues _idx = 1/`nperiods' {
                    local _col = `_idx'
                    local _att_se_val = el(`att_se_pool', 1, `_col')
                    local rowcell : display %12.4f `_att_se_val'
                    local rowline `"`rowline'`rowcell'"'
                }
                local _att_se_avg = el(`att_se_pool', 1, `avg_col')
                local rowcell : display %12.4f `_att_se_avg'
                local rowline `"`rowline'`rowcell'"'
            }
            else {
                forvalues _idx = 1/`nperiods' {
                    local _src = `_idx'
                    local _att_se_val = el(`att_se_pool', 1, `_src')
                    local rowcell : display %12.4f `_att_se_val'
                    local rowline `"`rowline'`rowcell'"'
                }
                local _att_se_avg = el(`att_se_pool', 1, `avg_col')
                local rowcell : display %12.4f `_att_se_avg'
                local rowline `"`rowline'`rowcell'"'
            }
            di as text `"`rowline'"'
        }

        // Grouped bootstrap replay stores pooled mean/SE/CI objects, so the
        // public replay summary should surface the pooled confidence interval
        // contract and honor replay level() the same way the serial ATT table
        // does. Point-estimate grouped replay has no public pooled CI bundle.
        if !`has_live_point' {
            local has_pooled_ci = 0
            local use_stored_pool_ci = 0
            tempname att_ci_lo_pool att_ci_hi_pool
            if `use_trim_boot' {
                capture confirm matrix e(att_ci_lower_trim)
                if _rc == 0 {
                    capture confirm matrix e(att_ci_upper_trim)
                    if _rc == 0 {
                        matrix `att_ci_lo_pool' = e(att_ci_lower_trim)
                        matrix `att_ci_hi_pool' = e(att_ci_upper_trim)
                        local has_pooled_ci = 1
                        local use_stored_pool_ci = 1
                    }
                }
            }
            else {
                capture confirm matrix e(att_ci_lower_pool)
                if _rc == 0 {
                    capture confirm matrix e(att_ci_upper_pool)
                    if _rc == 0 {
                        matrix `att_ci_lo_pool' = e(att_ci_lower_pool)
                        matrix `att_ci_hi_pool' = e(att_ci_upper_pool)
                        local has_pooled_ci = 1
                        local use_stored_pool_ci = 1
                    }
                }
            }

            local pooled_level = .
            capture local pooled_level = e(level)
            if _rc == 0 & !missing(`pooled_level') {
                if abs(`pooled_level' - `level') > 1e-8 {
                    local use_stored_pool_ci = 0
                }
            }
            local has_pooled_se = 0
            capture confirm matrix `att_se_pool'
            if _rc == 0 {
                local has_pooled_se = 1
            }
            local show_pooled_ci = (`has_pooled_ci' | `has_pooled_se')

            if `show_pooled_ci' {
                local z_crit = invnormal(1 - (100 - `level') / 200)
                di as text "Pooled CI [`level'%]"
                forvalues _idx = 1/`nperiods' {
                    local period_token : word `_idx' of `periodlist'
                    local _src = `_idx'
                    local _lo = .
                    local _hi = .
                    if `use_stored_pool_ci' {
                        local _lo = el(`att_ci_lo_pool', 1, `_src')
                        local _hi = el(`att_ci_hi_pool', 1, `_src')
                    }
                    else if `has_pooled_se' {
                        local _mean = el(`att_mean_pool', 1, `_src')
                        local _se = el(`att_se_pool', 1, `_src')
                        if !missing(`_mean') & !missing(`_se') {
                            local _lo = `_mean' - `z_crit' * `_se'
                            local _hi = `_mean' + `z_crit' * `_se'
                        }
                    }
                    di as text "  ATT_`period_token' = [" as result %6.4f `_lo' ///
                        as text ", " as result %6.4f `_hi' as text "]"
                }
                local _avg_lo = .
                local _avg_hi = .
                if `use_stored_pool_ci' {
                    local _avg_lo = el(`att_ci_lo_pool', 1, `avg_col')
                    local _avg_hi = el(`att_ci_hi_pool', 1, `avg_col')
                }
                else if `has_pooled_se' {
                    local _avg_mean = el(`att_mean_pool', 1, `avg_col')
                    local _avg_se = el(`att_se_pool', 1, `avg_col')
                    if !missing(`_avg_mean') & !missing(`_avg_se') {
                        local _avg_lo = `_avg_mean' - `z_crit' * `_avg_se'
                        local _avg_hi = `_avg_mean' + `z_crit' * `_avg_se'
                    }
                }
                di as text "  ATT_avg = [" as result %6.4f `_avg_lo' ///
                    as text ", " as result %6.4f `_avg_hi' as text "]"
            }
        }

        di as text "{hline 78}"
        di as text "Note: ATT computed via group-specific workers and replayed from stored e() results"
        if `use_trim_boot' {
            di as text "      Canonical grouped bootstrap replay uses the trimmed pooled track."
        }
        capture local _nboot = e(bootstrap)
        if _rc != 0 | missing(`_nboot') {
            capture local _nboot = e(nboot)
        }
        if _rc == 0 & !missing(`_nboot') & `_nboot' > 0 {
            di as text "Bootstrap replications" _col(30) "=" _col(32) as result %5.0f `_nboot'
        }
        if `has_live_point' {
            capture local _point_seed = e(point_seed)
            if _rc != 0 | missing(`_point_seed') {
                capture local _point_seed = e(seed)
            }
            if _rc == 0 & !missing(`_point_seed') {
                di as text "Grouped point seed" _col(30) "=" ///
                    _col(32) as result %10.0f `_point_seed'
            }
        }
        else {
            capture local _inner_seed = e(inner_seed)
            if _rc == 0 & !missing(`_inner_seed') {
                di as text "ATT simulation seed" _col(30) "=" ///
                    _col(32) as result %10.0f `_inner_seed'
            }
            capture local _boot_seed = e(industry_seed)
            if _rc != 0 | missing(`_boot_seed') {
                capture local _boot_seed = e(seed_outer)
            }
            if _rc != 0 | missing(`_boot_seed') {
                capture local _boot_seed = e(seed)
            }
            if _rc == 0 & !missing(`_boot_seed') {
                di as text "Grouped bootstrap seed" _col(30) "=" ///
                    _col(32) as result %10.0f `_boot_seed'
            }
        }
        exit
    }
    
    // 1. Get group info
    local n_groups = e(n_groups)
    
    // 2. Display group header
    di as text _n "{hline 78}"
    di as text " Results by: `by'"
    di as text "{hline 78}"
    
    // 3. Loop through groups - display per-group results
    forvalues g = 1/`n_groups' {
        // Get group label and stats
        local glabel = "`e(by_label_`g')'"
        capture local gn = e(N_group_`g')
        capture local gtreated = e(N_treated_`g')
        
        di as text _n "{hline 78}"
        di as text " Group `g': `glabel'"
        if !missing(`gn') {
            di as text "   N = " as result %8.0fc `gn' ///
                as text "   Treated = " as result %5.0fc `gtreated'
        }
        di as text "{hline 78}"
        
        // Display group production function params (if available)
        capture confirm matrix e(b_`g')
        if _rc == 0 {
            di as text _n " Production Function (Group `g'):"
            tempname bg
            matrix `bg' = e(b_`g')
            local ncols = colsof(`bg')
            local cnames : colnames `bg'
            forvalues j = 1/`ncols' {
                local vname : word `j' of `cnames'
                local bval = el(`bg', 1, `j')
                di as text _col(5) "`vname'" _col(20) "=" _col(22) as result %12.6f `bval'
            }
        }
        
        // Display group evolution params (if available)
        capture confirm matrix e(rho_0_`g')
        if _rc == 0 {
            di as text _n " Evolution Parameters (Group `g'):"
            tempname rho0g rho1g
            matrix `rho0g' = e(rho_0_`g')
            matrix `rho1g' = e(rho_1_`g')
            local p = colsof(`rho0g') - 1
            
            local rowlbl_0 "constant"
            local rowlbl_1 "omega"
            local rowlbl_2 "omega^2"
            local rowlbl_3 "omega^3"
            
            di as text _col(5) "Parameter" _col(22) "h0" _col(38) "h1"
            forvalues j = 0/`p' {
                local rj = el(`rho0g', 1, `j'+1)
                local ej = el(`rho1g', 1, `j'+1)
                local lbl = "`rowlbl_`j''"
                di as text _col(5) "`lbl'" ///
                    _col(20) as result %12.6f `rj' ///
                    _col(36) as result %12.6f `ej'
            }
        }
        
        // Display group ATT (if available and noatt not specified)
        if "`noatt'" == "" {
            capture confirm matrix e(att_`g')
            if _rc == 0 {
                di as text _n " ATT (Group `g'):"
                tempname attg
                matrix `attg' = e(att_`g')
                local nrows = rowsof(`attg')
                local ncols_g = colsof(`attg')
                
                di as text _col(5) "Period" _col(18) "ATT" _col(36) "N"
                di as text _col(5) "{hline 40}"
                
                // Determine N column index (col 3 for 3-col, col 4 for 5-col)
                local n_col = 3
                if `ncols_g' >= 5 local n_col = 4
                
                forvalues i = 1/`nrows' {
                    local ell = el(`attg', `i', 1)
                    local aval = el(`attg', `i', 2)
                    local nval = el(`attg', `i', `n_col')
                    
                    if !missing(`aval') {
                        di as text _col(5) %6.0f `ell' ///
                            _col(16) as result %10.4f `aval' ///
                            _col(34) as result %8.0f `nval'
                    }
                    else {
                        di as text _col(5) %6.0f `ell' _col(16) "."
                    }
                }
            }
        }
    }
    
    // 4. Table 2 style summary (always shown when by() is used)
    capture confirm matrix e(att_bygroup)
    if _rc == 0 & "`noatt'" == "" {
        di as text _n "{hline 78}"
        di as text " ATT Summary by Group (Table 2 style)"
        di as text "{hline 78}"
        di as text _col(5) "Group" _col(25) "Mean ATT" _col(40) "SE" ///
            _col(52) "N(treated)" _col(68) "Contrib."
        di as text "{hline 78}"
        
        tempname summat
        matrix `summat' = e(att_bygroup)
        local nsumrows = rowsof(`summat')
        local rnames : rownames `summat'
        
        forvalues g = 1/`nsumrows' {
            local glbl : word `g' of `rnames'
            local matt = el(`summat', `g', 1)
            local mse = el(`summat', `g', 2)
            local mn = el(`summat', `g', 3)
            local mcontrib = el(`summat', `g', 4)
            
            // Significance marker
            local sig ""
            if !missing(`mse') & `mse' > 0 {
                local tstat = abs(`matt' / `mse')
                if `tstat' > 2.576 local sig "***"
                else if `tstat' > 1.960 local sig "**"
                else if `tstat' > 1.645 local sig "*"
            }
            
            di as text _col(3) "`glbl'" ///
                _col(23) as result %10.4f `matt' as text "`sig'" ///
                _col(38) as result %8.4f `mse' ///
                _col(50) as result %8.0f `mn' ///
                _col(64) as result %8.1f `mcontrib' as text "%"
        }
        di as text "{hline 78}"
    }
    
    // 5. Pooled results (only when aggregate is specified)
    if "`aggregate'" != "" {
        di as text _n "{hline 78}"
        di as text " Pooled Results (All Groups)   [aggregate]"
        di as text "{hline 78}"
        
        // Display pooled ATT from main e(att_table)
        if "`noatt'" == "" {
            capture confirm matrix e(att_table)
            if _rc == 0 {
                tempname attp
                matrix `attp' = e(att_table)
                local nprows = rowsof(`attp')
                
                di as text _col(5) "Period" _col(18) "ATT" _col(36) "N"
                di as text _col(5) "{hline 40}"
                
                forvalues i = 1/`nprows' {
                    local ell = el(`attp', `i', 1)
                    local aval = el(`attp', `i', 2)
                    local nval = el(`attp', `i', 4)
                    
                    if !missing(`aval') {
                        di as text _col(5) %6.0f `ell' ///
                            _col(16) as result %10.4f `aval' ///
                            _col(34) as result %8.0f `nval'
                    }
                }
            }
        }
        di as text "{hline 78}"
    }
end


// =========================================================================
// Compact display program (default non-verbose mode)
// =========================================================================

program define _pte_display_compact
    version 14.0
    syntax [, NOAtt Level(cilevel)]
    
    // Default confidence level
    if "`level'" == "" local level = 95
    
    // --- Header with two-column layout ---
    local N = e(N)
    local N_gmm = e(N_gmm)
    capture local N_firms = e(N_g)
    if _rc != 0 | missing(`N_firms') {
        local N_firms = .
    }
    
    local pfunc = "`e(pfunc)'"
    if "`pfunc'" == "cd" {
        local pfunc_display "Cobb-Douglas"
    }
    else {
        local pfunc_display "Translog"
    }
    
    display ""
    display as text "{hline 70}"
    display as text "Production Function Estimates" ///
        _col(45) "Number of obs   = " as result %9.0fc `N'
    display as text "  Method: ACF with CLK correction" ///
        _col(45) "GMM sample      = " as result %9.0fc `N_gmm'
    
    local trimeps = e(trimeps)
    if `trimeps' == 1 {
        display as text "  Trim eps0: 1%-99%" ///
            _col(45) "Firms           = " as result %9.0fc `N_firms'
    }
    else {
        display as text "  Trim eps0: off" ///
            _col(45) "Firms           = " as result %9.0fc `N_firms'
    }
    display as text "{hline 70}"
    
    // --- Coefficient table ---
    if "`pfunc'" == "cd" {
        capture local bl = e(beta_l)
        capture local bk = e(beta_k)
        if !missing(`bl') & !missing(`bk') {
            display as text _col(5) "beta_l" _col(20) "= " as result %9.6f `bl'
            display as text _col(5) "beta_k" _col(20) "= " as result %9.6f `bk'
        }
        else {
            // Try from e(b) matrix
            capture confirm matrix e(b)
            if _rc == 0 {
                tempname _cb
                matrix `_cb' = e(b)
                local bl = `_cb'[1, 1]
                local bk = `_cb'[1, 2]
                display as text _col(5) "beta_l" _col(20) "= " as result %9.6f `bl'
                display as text _col(5) "beta_k" _col(20) "= " as result %9.6f `bk'
            }
        }
        // Show GMM objective value
        capture local fval = e(fval)
        if !missing(`fval') {
            display as text _col(5) "GMM obj" _col(20) "= " as result %9.2e `fval'
        }
    }
    else {
        // Translog - show all beta coefficients
        capture local bl = e(beta_l)
        capture local bk = e(beta_k)
        capture local bll = e(beta_ll)
        capture local bkk = e(beta_kk)
        capture local blk = e(beta_lk)
        if !missing(`bl') {
            display as text _col(5) "beta_l" _col(20) "= " as result %9.6f `bl'
        }
        if !missing(`bk') {
            display as text _col(5) "beta_k" _col(20) "= " as result %9.6f `bk'
        }
        if !missing(`bll') {
            display as text _col(5) "beta_ll" _col(20) "= " as result %9.6f `bll'
        }
        if !missing(`bkk') {
            display as text _col(5) "beta_kk" _col(20) "= " as result %9.6f `bkk'
        }
        if !missing(`blk') {
            display as text _col(5) "beta_lk" _col(20) "= " as result %9.6f `blk'
        }
        capture local fval = e(fval)
        if !missing(`fval') {
            display as text _col(5) "GMM obj" _col(20) "= " as result %9.2e `fval'
        }
    }
    
    // --- ATT results ---
    if "`noatt'" == "" {
        display as text "{hline 70}"
        local attperiods = e(attperiods_max)
        local nsim = e(nsim)
        display as text "ATT Results (event time 0..`attperiods')" ///
            _col(45) "Sim. paths      = " as result %9.0fc `nsim'
        display as text "{hline 70}"
        
        // Check for bootstrap inference
        local has_bs_se = 0
        local bootstrap_reps = .
        capture local bootstrap_reps = e(bootstrap)
        if _rc != 0 | missing(`bootstrap_reps') {
            capture local bootstrap_reps = e(breps)
        }
        if _rc != 0 | missing(`bootstrap_reps') {
            capture local bootstrap_reps = e(nboot)
        }
        if !missing(`bootstrap_reps') & `bootstrap_reps' > 0 {
            capture confirm matrix e(att_se)
            if _rc == 0 {
                local has_bs_se = 1
            }
        }
        
        // Try to display ATT table from result_table_trim or att_table
        tempname att_src
        local has_att_src = 0
        capture confirm matrix e(result_table_trim)
        if _rc == 0 {
            matrix `att_src' = e(result_table_trim)
            local has_att_src = 1
        }
        else {
            capture confirm matrix e(result_table_raw)
            if _rc == 0 {
                matrix `att_src' = e(result_table_raw)
                local has_att_src = 1
            }
            else {
                capture confirm matrix e(att_table)
                if _rc == 0 {
                    matrix `att_src' = e(att_table)
                    local has_att_src = 1
                }
            }
        }
        
        if `has_att_src' {
            local nrows = rowsof(`att_src')
            local ncols = colsof(`att_src')
            
            // Determine display rows (exclude overall row if present)
            local display_rows = `nrows'
            local has_overall_row = 0
            local last_nt = el(`att_src', `nrows', 1)
            if !missing(`last_nt') & `last_nt' < 0 {
                local has_overall_row = 1
                local display_rows = `nrows' - 1
            }
            
            // Table header
            if `has_bs_se' {
                display as text " {ralign 6:Period} {c |} {ralign 10:ATT} {ralign 10:Std.Err.} {ralign 22:[`level'% Conf. Int.]}"
                display as text " {hline 7}{c +}{hline 55}"
            }
            else {
                display as text " {ralign 6:Period} {c |} {ralign 10:ATT} {ralign 10:Std.Dev.} {ralign 8:N}"
                display as text " {hline 7}{c +}{hline 35}"
            }
            
            // Bootstrap SE and CI matrices
            if `has_bs_se' {
                tempname se_mat ci_lo_mat ci_hi_mat
                matrix `se_mat' = e(att_se)
                local has_ci = 0
                capture confirm matrix e(att_ci_lower)
                if _rc == 0 {
                    capture confirm matrix e(att_ci_upper)
                    if _rc == 0 {
                        local has_ci = 1
                        matrix `ci_lo_mat' = e(att_ci_lower)
                        matrix `ci_hi_mat' = e(att_ci_upper)
                    }
                }
            }
            
            // Display period rows
            forvalues i = 1/`display_rows' {
                local ell = el(`att_src', `i', 1)
                local att_val = el(`att_src', `i', 2)
                
                if missing(`att_val') {
                    display as text " {ralign 6:" %3.0f `ell' "} {c |} " as text "."
                    continue
                }
                
                if `has_bs_se' {
                    // Get SE
                    local se_val = .
                    local se_rows = rowsof(`se_mat')
                    local se_cols = colsof(`se_mat')
                    if `se_rows' == 1 & `se_cols' >= `i' {
                        local se_val = el(`se_mat', 1, `i')
                    }
                    else if `se_cols' == 1 & `se_rows' >= `i' {
                        local se_val = el(`se_mat', `i', 1)
                    }
                    // Significance stars
                    local sig ""
                    if !missing(`se_val') & `se_val' > 0 {
                        local t_stat = abs(`att_val' / `se_val')
                        if `t_stat' > 2.576 {
                            local sig "***"
                        }
                        else if `t_stat' > 1.960 {
                            local sig "**"
                        }
                        else if `t_stat' > 1.645 {
                            local sig "*"
                        }
                    }
                    // CI
                    local ci_lo = .
                    local ci_hi = .
                    if `has_ci' {
                        local ci_lo_cols = colsof(`ci_lo_mat')
                        local ci_lo_rows = rowsof(`ci_lo_mat')
                        if `ci_lo_rows' == 1 & `ci_lo_cols' >= `i' {
                            local ci_lo = el(`ci_lo_mat', 1, `i')
                            local ci_hi = el(`ci_hi_mat', 1, `i')
                        }
                        else if `ci_lo_cols' == 1 & `ci_lo_rows' >= `i' {
                            local ci_lo = el(`ci_lo_mat', `i', 1)
                            local ci_hi = el(`ci_hi_mat', `i', 1)
                        }
                    }
                    display as text " {ralign 6:" %3.0f `ell' "} {c |} " ///
                        as result %10.4f `att_val' "`sig'" ///
                        as text "  (" as result %7.4f `se_val' as text ")" ///
                        as text "  [" as result %8.4f `ci_lo' ///
                        as text "," as result %8.4f `ci_hi' as text "]"
                }
                else {
                    // Point estimate: show ATT, sd, N
                    local sd_val = .
                    if `ncols' >= 3 {
                        local sd_val = el(`att_src', `i', 3)
                    }
                    local n_obs = .
                    if `ncols' >= 4 {
                        local n_obs = el(`att_src', `i', 4)
                    }
                    display as text " {ralign 6:" %3.0f `ell' "} {c |} " ///
                        as result %10.4f `att_val' ///
                        as text "  " as result %10.4f `sd_val' ///
                        as text "  " as result %8.0f `n_obs'
                }
            }
            
            // Overall row
            display as text " {hline 7}{c +}{hline 55}"
            capture local att_avg = e(ATT_avg_trim)
            if _rc != 0 | missing(`att_avg') {
                capture local att_avg = e(ATT_avg)
            }
            if !missing(`att_avg') {
                if `has_bs_se' {
                    // Get overall SE
                    local se_overall = .
                    capture local se_overall = e(bs_se)
                    if _rc != 0 | missing(`se_overall') {
                        capture local se_overall = e(bs_se_trim)
                    }
                    local sig ""
                    if !missing(`se_overall') & `se_overall' > 0 {
                        local t_stat = abs(`att_avg' / `se_overall')
                        if `t_stat' > 2.576 {
                            local sig "***"
                        }
                        else if `t_stat' > 1.960 {
                            local sig "**"
                        }
                        else if `t_stat' > 1.645 {
                            local sig "*"
                        }
                    }
                    local ci_lo = .
                    local ci_hi = .
                    capture local ci_lo = e(ci_lo)
                    if _rc != 0 | missing(`ci_lo') {
                        capture local ci_lo = e(ci_lo_trim)
                    }
                    capture local ci_hi = e(ci_hi)
                    if _rc != 0 | missing(`ci_hi') {
                        capture local ci_hi = e(ci_hi_trim)
                    }
                    display as text " {ralign 6:avg} {c |} " ///
                        as result %10.4f `att_avg' "`sig'" ///
                        as text "  (" as result %7.4f `se_overall' as text ")" ///
                        as text "  [" as result %8.4f `ci_lo' ///
                        as text "," as result %8.4f `ci_hi' as text "]"
                }
                else {
                    display as text " {ralign 6:avg} {c |} " ///
                        as result %10.4f `att_avg'
                }
            }
        }
        else {
            // Fallback: show scalar ATT
            capture local att_avg = e(ATT_avg_trim)
            if _rc != 0 | missing(`att_avg') {
                capture local att_avg = e(ATT_avg)
            }
            if !missing(`att_avg') {
                display as text " ATT (avg)  = " as result %10.4f `att_avg'
            }
        }
        display as text "{hline 70}"
    }
    display ""
end
