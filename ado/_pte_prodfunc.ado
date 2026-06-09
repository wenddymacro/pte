*! _pte_prodfunc.ado
*! Internal orchestrator for baseline production-function estimation.
*! Runs transition tagging, stage-1 proxy regression, GMM matrix assembly,
*! optimization, and the e(sample)/omega bridge consumed downstream.

version 14.0
capture program drop _pte_prodfunc
program define _pte_prodfunc, eclass
	version 14.0

	local _pte_clear_eclass "capture ereturn clear"
	local _pte_clear_estimates "capture estimates clear"

	// Successful runs publish a data-side readiness marker consumed by
	// downstream recovery helpers. Drop any stale marker up front so failed
	// reruns cannot masquerade as a current producer contract.
	capture confirm variable _pte_prodfunc_ready, exact
	if !_rc {
		capture drop _pte_prodfunc_ready
	}

	// A fresh rerun invalidates any previously recovered omega. If the
	// producer fails before reaching its success boundary, downstream
	// helpers must not be able to reuse the stale productivity object.
	capture confirm variable omega, exact
	if !_rc {
		quietly ds
		local _pte_allvars `"`r(varlist)'"'
		local _pte_keepvars ""
		foreach _pte_var of local _pte_allvars {
			if "`_pte_var'" != "omega" {
				local _pte_keepvars `"`_pte_keepvars' `_pte_var'"'
			}
		}
		quietly keep `_pte_keepvars'
	}

	// Preserve the raw option string so compatibility aliases can
	// distinguish omitted defaults from explicit poly()/omegapoly() inputs.
	local _pte_cmdline `"`0'"'
	foreach _pte_input_opt in lny free state proxy {
		local _pte_`_pte_input_opt'_literal ""
		if regexm(lower(`"`_pte_cmdline'"'), ///
			"(^|[ ,])`_pte_input_opt'[(]([^)]*)[)]") {
			local _pte_`_pte_input_opt'_literal `"`=regexs(2)'"'
			local _pte_`_pte_input_opt'_literal = ///
				lower(strtrim(`"`_pte_`_pte_input_opt'_literal'"'))
		}
	}
	local _pte_has_poly = regexm(lower(`"`_pte_cmdline'"'), "(^|[ ,])poly[(]")
	local _pte_has_omegapoly = regexm(lower(`"`_pte_cmdline'"'), "(^|[ ,])omegapoly[(]")
	
	// ================================================================
	// Parse the full production-function contract in one place so alias
	// handling happens before any helper mutates defaults or samples.
	capture noisily syntax, TREATment(name) ID(varname) Time(varname numeric) ///
		[LNY(varname numeric) FREE(varname numeric) PROXY(varname numeric) ///
				 STATE(varname numeric) CONTROL(varlist numeric) PFUNC(string) POLY(integer 3) GENLAG ///
				 OMEGAPOLY(integer 3) INDustry(varname) BYINDustry MULTISTART ///
				 TTRENDBY(varname) TTRENDVARS(varlist numeric) ///
				 GMMINIT(numlist) ///
				 MINsample(integer 30) REPLACE NODIAGnose STRICT noREPORT ///
				 DOPOOLEDZ ///
			 LEGACYFLOATPHI ///
			 TREATDEPENDENT ///
			 TOUSE(name)]
	if _rc {
		local _pte_syntax_rc = _rc
		`_pte_clear_eclass'
		`_pte_clear_estimates'
		exit `_pte_syntax_rc'
	}

	// poly() is the legacy compatibility alias for the evolution-order
	// option. The first-stage proxy basis remains fixed at the paper/DO
	// cubic specification regardless of the alias value below.
	if `_pte_has_poly' {
		if `poly' < 1 | `poly' > 4 {
			di as error "[pte] poly() must be between 1 and 4"
			`_pte_clear_eclass'
			`_pte_clear_estimates'
			exit 198
		}
		if `_pte_has_omegapoly' & `omegapoly' != `poly' {
			di as error "[pte] Cannot specify conflicting poly(`poly') and omegapoly(`omegapoly')"
			`_pte_clear_eclass'
			`_pte_clear_estimates'
			exit 198
		}
		local omegapoly = `poly'
	}
	if `omegapoly' < 1 | `omegapoly' > 4 {
		di as error "[pte] omegapoly() must be between 1 and 4"
		`_pte_clear_eclass'
		`_pte_clear_estimates'
		exit 198
	}

	local _pte_lny_resolved = lower(`"`lny'"')
	local _pte_free_resolved = lower(`"`free'"')
	local _pte_state_resolved = lower(`"`state'"')
	local _pte_proxy_resolved = lower(`"`proxy'"')
	if `"`_pte_lny_literal'"' != "" & `"`_pte_lny_literal'"' != `"`_pte_lny_resolved'"' {
		di as error "[pte] variable " as result "`_pte_lny_literal'" as error " not found"
		`_pte_clear_eclass'
		`_pte_clear_estimates'
		exit 111
	}
	if `"`_pte_free_literal'"' != "" & `"`_pte_free_literal'"' != `"`_pte_free_resolved'"' {
		di as error "[pte] variable " as result "`_pte_free_literal'" as error " not found"
		`_pte_clear_eclass'
		`_pte_clear_estimates'
		exit 111
	}
	if `"`_pte_state_literal'"' != "" & `"`_pte_state_literal'"' != `"`_pte_state_resolved'"' {
		di as error "[pte] variable " as result "`_pte_state_literal'" as error " not found"
		`_pte_clear_eclass'
		`_pte_clear_estimates'
		exit 111
	}
	if `"`_pte_proxy_literal'"' != "" & `"`_pte_proxy_literal'"' != `"`_pte_proxy_resolved'"' {
		di as error "[pte] variable " as result "`_pte_proxy_literal'" as error " not found"
		`_pte_clear_eclass'
		`_pte_clear_estimates'
		exit 111
	}

	// Preserve the literal treatment() token until an exact-name check.
	capture confirm variable `treatment', exact
	if _rc {
		di as error "[pte] variable `treatment' not found"
		`_pte_clear_eclass'
		`_pte_clear_estimates'
		exit 111
	}
	capture confirm numeric variable `treatment'
	if _rc {
		di as error "[pte] variable `treatment' must be numeric"
		`_pte_clear_eclass'
		`_pte_clear_estimates'
		exit 111
	}
	
	// ================================================================
	// Caller-provided touse() defines the universe for both current and lagged
	// observations. Later stages refine it, but they must never resurrect rows
	// excluded here.
	// ================================================================
	if "`touse'" != "" {
		capture confirm variable `touse', exact
		if _rc {
			di as error "[pte] touse variable `touse' not found"
			`_pte_clear_eclass'
			`_pte_clear_estimates'
			exit 111
		}
		capture confirm numeric variable `touse'
		if _rc {
			di as error "[pte] touse variable `touse' must be numeric"
			`_pte_clear_eclass'
			`_pte_clear_estimates'
			exit 111
		}
	}

	// If touse not provided by caller, create default (all observations)
	if "`touse'" == "" {
		tempvar touse
		gen byte `touse' = 1
	}
	
	// Mark out observations with missing values in key variables
	if "`lny'" != "" {
		markout `touse' `lny'
	}
	if "`free'" != "" {
		markout `touse' `free'
	}
	if "`state'" != "" {
		markout `touse' `state'
	}
	if "`proxy'" != "" {
		markout `touse' `proxy'
	}
	if "`control'" != "" {
		markout `touse' `control'
	}
	markout `touse' `treatment'

	tempvar _pte_active_sample
	quietly gen byte `_pte_active_sample' = (`touse' != 0 & !missing(`touse'))

	// Use the declared xtset delta() whenever the active panel declaration
	// matches the id()/time() contract for this run. The DO workflow and the
	// GMM helper both define admissible lags through Stata's L. operator, so
	// all producer-side sample diagnostics and the final e(sample) bridge must
	// use the same adjacency law instead of inferring it from observed gaps.
	quietly xtset
	local _pte_xt_panelvar "`r(panelvar)'"
	local _pte_xt_timevar "`r(timevar)'"
	local _pte_declared_tsdelta = .
	if "`_pte_xt_panelvar'" == "`id'" & "`_pte_xt_timevar'" == "`time'" {
		local _pte_declared_tsdelta = real("`r(tdelta)'")
	}
	
	// Validate sample size
	quietly count if `_pte_active_sample'
	local N_touse = r(N)
	
	if `N_touse' == 0 {
		di as error "no observations"
		`_pte_clear_eclass'
		`_pte_clear_estimates'
		exit 2000
	}

	// The paper and industry-specific DO paths estimate one industry at a time.
	// If callers request byindustry while still passing multiple industries in
	// the active sample, fail fast instead of drifting into a pooled estimator.
	if "`byindustry'" != "" & "`industry'" != "" {
		quietly levelsof `industry' if `_pte_active_sample' & !missing(`industry'), ///
			local(_pte_byindustry_levels)
		local _pte_byindustry_count : word count `_pte_byindustry_levels'
		if `_pte_byindustry_count' == 0 {
			di as error "[pte] byindustry requires at least one nonmissing industry() value in the active sample"
			`_pte_clear_eclass'
			exit 498
		}
		if `_pte_byindustry_count' > 1 {
			di as error "[pte] byindustry requires the active sample to contain exactly one industry"
			di as error "[pte]        Current sample contains `_pte_byindustry_count' industries"
			di as error "[pte]        Split the sample by industry first, or drop byindustry for pooled estimation"
			`_pte_clear_eclass'
			exit 498
		}
	}
	
	if `N_touse' < `minsample' {
		di as text "Warning: Small sample size (`N_touse' observations, minimum recommended: `minsample')"
	}
	
	// Sample selection summary (when report is not suppressed)
	if "`report'" == "" {
		di as text ""
		di as text "Sample Selection Summary:"
		di as text "  Total observations:      " as result %10.0f _N
		di as text "  After selection:         " as result %10.0f `N_touse'
		if `N_touse' < _N {
			local _n_excluded = _N - `N_touse'
			di as text "  Excluded observations:   " as result %10.0f `_n_excluded'
		}
	}
	
	// Treatment-dependent production functions use a separate execution path
	// because the treatdependent branch consumes interacted inputs rather than the
	// baseline CLK moment-condition pipeline.
	if "`treatdependent'" != "" {
		if "`report'" == "" {
			di as text ""
			di as text "Mode: Treatment-dependent production function (Appendix C.1)"
		}
		
		// Materialize interacted inputs once and cache the returned varlists
		// before later r() calls overwrite them.
		local _interact_opts "free(`free') state(`state') treatment(`treatment')"
		if "`pfunc'" != "" {
			local _interact_opts "`_interact_opts' pfunc(`pfunc')"
		}
		
		capture noisily _pte_treatdep_interact, `_interact_opts'
		if _rc {
			local _pte_treatdep_interact_rc = _rc
			`_pte_clear_eclass'
			`_pte_clear_estimates'
			exit `_pte_treatdep_interact_rc'
		}
		
		// Save the r-class payload immediately because subsequent helpers reuse r().
		local _td_free_vars  "`r(free_vars)'"
		local _td_state_vars "`r(state_vars)'"
		local _td_n_interact = r(n_interact)
		local _td_n_free     = r(n_free)
		local _td_n_state    = r(n_state)
	}
	
	// Route the effective input varlists after interaction generation so every
	// downstream call sees one consistent contract.
	if "`treatdependent'" != "" {
		local _pte_free_vars  "`_td_free_vars'"
		local _pte_state_vars "`_td_state_vars'"
	}
	else {
		local _pte_free_vars  "`free'"
		local _pte_state_vars "`state'"
	}
	
	// Tag transition periods before any GMM object is built. Theorem 3.1 uses
	// only stable-treatment rows as current observations, matching the DO files'
	// `drop if mid==1` convention.
	local _trans_opts "treatment(`treatment') id(`id') time(`time') minsample(`minsample')"
	local _trans_opts "`_trans_opts' touse(`_pte_active_sample')"
	if "`replace'" != "" local _trans_opts "`_trans_opts' replace"
	if "`report'" != "" local _trans_opts "`_trans_opts' noreport"

	// Re-running the internal transition step must be idempotent over
	// package-owned helpers already materialized by an upstream PTE module.
	// Only recycle reserved outputs and the legacy alias when their package
	// labels match, leaving user-owned generic columns untouched.
	local _pte_has_pkg_mid 0
	capture confirm variable _pte_mid, exact
	if !_rc {
		local _pte_existing_mid_label : variable label _pte_mid
		if `"`_pte_existing_mid_label'"' == "PTE: transition period indicator (1=transition)" {
			local _pte_has_pkg_mid 1
			capture drop _pte_mid
		}
		else {
			di as error "[pte] variable _pte_mid already exists and is not a package-owned transition helper"
			di as error "[pte]        Drop or rename _pte_mid before calling _pte_prodfunc"
			`_pte_clear_eclass'
			`_pte_clear_estimates'
			exit 110
		}
	}

	capture confirm variable mid, exact
	if !_rc {
		local _pte_mid_label : variable label mid
		if `_pte_has_pkg_mid' & `"`_pte_mid_label'"' == "Legacy alias for _pte_mid" {
			capture drop mid
		}
	}

	capture confirm variable G, exact
	if !_rc {
		local _pte_existing_G_label : variable label G
		if `_pte_has_pkg_mid' & `"`_pte_existing_G_label'"' == "Treatment switch indicator (-1/0/+1)" {
			capture drop G
		}
		else if !`_pte_has_pkg_mid' & `"`_pte_existing_G_label'"' == "Treatment switch indicator (-1/0/+1)" {
			di as error "[pte] variable G already exists with the package transition-helper label"
			di as error "[pte]        but no package-owned _pte_mid is present; clean the helper state before rerunning _pte_prodfunc"
			`_pte_clear_eclass'
			`_pte_clear_estimates'
			exit 110
		}
	}

	capture confirm variable mid_lag, exact
	if !_rc {
		local _pte_existing_midlag_label : variable label mid_lag
		if `_pte_has_pkg_mid' & `"`_pte_existing_midlag_label'"' == "Lagged transition period indicator" {
			capture drop mid_lag
		}
		else if !`_pte_has_pkg_mid' & `"`_pte_existing_midlag_label'"' == "Lagged transition period indicator" {
			di as error "[pte] variable mid_lag already exists with the package transition-helper label"
			di as error "[pte]        but no package-owned _pte_mid is present; clean the helper state before rerunning _pte_prodfunc"
			`_pte_clear_eclass'
			`_pte_clear_estimates'
			exit 110
		}
	}

	// _pte_transition still materializes legacy helpers G and mid_lag for its
	// own diagnostics. They are not part of the public baseline input contract,
	// so shield user-owned exact aliases before stage 1 and restore them
	// immediately after harvesting the transition counts needed downstream.
	local _pte_restore_user_mid 0
	local _pte_restore_user_G 0
	local _pte_restore_user_midlag 0
	tempvar _pte_user_mid_hold _pte_user_G_hold _pte_user_midlag_hold
	capture confirm variable mid, exact
	if !_rc {
		local _pte_mid_label : variable label mid
		if `"`_pte_mid_label'"' != "Legacy alias for _pte_mid" {
			rename mid `_pte_user_mid_hold'
			local _pte_restore_user_mid 1
		}
	}
	capture confirm variable G, exact
	if !_rc {
		local _pte_G_label : variable label G
		if `"`_pte_G_label'"' != "Treatment switch indicator (-1/0/+1)" {
			rename G `_pte_user_G_hold'
			local _pte_restore_user_G 1
		}
	}
	capture confirm variable mid_lag, exact
	if !_rc {
		local _pte_midlag_label : variable label mid_lag
		if `"`_pte_midlag_label'"' != "Lagged transition period indicator" {
			rename mid_lag `_pte_user_midlag_hold'
			local _pte_restore_user_midlag 1
		}
	}
	
	// NOTE: Inside a caller program, a successful subprogram does not reliably
	// reset _rc after earlier captured failures. Capture the transition worker
	// explicitly so grouped callers do not inherit a stale 111/198 and abort a
	// valid baseline path.
	capture noisily _pte_transition, `_trans_opts'
	local _pte_transition_rc = _rc
	
	// Copy the r-class transition counts now; later helpers reuse r().
	if `_pte_transition_rc' == 0 {
		local _n_trans      = r(n_trans)
		local _n_trans_up   = r(n_trans_up)
		local _n_trans_down = r(n_trans_down)
		local _n_stable_0   = r(n_stable_0)
		local _n_stable_1   = r(n_stable_1)
		local _n_total      = r(n_total)
		local _pct_excluded = r(pct_excluded)
		local _n_trans_lag  = r(n_trans_lag)
	}

	// Restore user-owned generic columns before any later stage or caller sees
	// the data again. The baseline estimator only carries _pte_mid forward.
	capture confirm variable mid, exact
	if !_rc {
		capture drop mid
	}
	capture confirm variable G, exact
	if !_rc {
		capture drop G
	}
	capture confirm variable mid_lag, exact
	if !_rc {
		capture drop mid_lag
	}
	if `_pte_restore_user_mid' {
		rename `_pte_user_mid_hold' mid
	}
	if `_pte_restore_user_G' {
		rename `_pte_user_G_hold' G
	}
	if `_pte_restore_user_midlag' {
		rename `_pte_user_midlag_hold' mid_lag
	}
	if `_pte_transition_rc' != 0 {
		`_pte_clear_eclass'
		`_pte_clear_estimates'
		exit `_pte_transition_rc'
	}

	local _pte_midvar "_pte_mid"
	capture confirm variable `_pte_midvar', exact
	if _rc {
		di as error "[pte] transition helper _pte_mid not found after _pte_transition"
		di as error "[pte] re-run _pte_transition or rerun _pte_prodfunc on a clean dataset"
		`_pte_clear_eclass'
		`_pte_clear_estimates'
		exit 111
	}
	
	// Build the current-period GMM support.
	// GMM estimation requires excluding transition periods (Theorem 3.1)
	// gmm_sample marks admissible current observations.
	// The external helper contract remains touse(), because lagged values from
	// transition rows are valid but lagged values from touse()==0 rows are not.
	// Design: ADR-010.3 - Stage 1 uses touse, Stage 2 uses gmm_sample
	tempvar gmm_sample _pte_gmm_report_sample _pte_gmm_gap _pte_gmm_delta_probe
	gen byte `gmm_sample' = `_pte_active_sample' & (`_pte_midvar' == 0)
	gen byte `_pte_gmm_report_sample' = `gmm_sample'
	quietly sort `id' `time'
	local _pte_gmm_tsdelta = `_pte_declared_tsdelta'
	if missing(`_pte_gmm_tsdelta') | `_pte_gmm_tsdelta' <= 0 {
		quietly by `id' (`time'): gen double `_pte_gmm_delta_probe' = ///
			`time' - `time'[_n-1] if _n > 1 & !mi(`time', `time'[_n-1])
		quietly summarize `_pte_gmm_delta_probe' if `_pte_gmm_delta_probe' > 0, meanonly
		local _pte_gmm_tsdelta = r(min)
	}
	if missing(`_pte_gmm_tsdelta') | `_pte_gmm_tsdelta' <= 0 {
		local _pte_gmm_tsdelta = 1
	}
	local _pte_gmm_tsdelta_tol = max(1e-10, abs(`_pte_gmm_tsdelta') * 1e-10)
	quietly by `id' (`time'): gen byte `_pte_gmm_gap' = ///
		(abs((`time' - `time'[_n-1]) - `_pte_gmm_tsdelta') > `_pte_gmm_tsdelta_tol') if _n > 1
	quietly by `id' (`time'): replace `_pte_gmm_gap' = 1 if _n == 1
	quietly replace `_pte_gmm_report_sample' = 0 if `_pte_gmm_gap' == 1
	quietly replace `_pte_gmm_report_sample' = 0 if _n > 1 & `_pte_active_sample'[_n-1] != 1
	
	// Fail early when every selected current observation is transitional.
	quietly count if `_pte_gmm_report_sample'
	local N_gmm = r(N)
	
	if `N_gmm' == 0 {
		di as error "[pte] All selected observations are transition periods"
		di as error "  No observations available for GMM estimation"
		`_pte_clear_eclass'
		`_pte_clear_estimates'
		exit 498
	}
	
	// The identification step needs stable untreated and stable treated rows on
	// the actual moment-condition support, not merely in the raw active sample.
	quietly count if `_pte_gmm_report_sample' & `treatment' == 0
	local n_stable_0_filtered = r(N)
	quietly count if `_pte_gmm_report_sample' & `treatment' == 1
	local n_stable_1_filtered = r(N)
	
	if `n_stable_0_filtered' == 0 | `n_stable_1_filtered' == 0 {
		di as error "[pte] Assumption 3.3 violated after if/in selection:"
		di as error "  Stable untreated (D=D_{-1}=0): `n_stable_0_filtered'"
		di as error "  Stable treated (D=D_{-1}=1):   `n_stable_1_filtered'"
		di as error "  Both groups must have observations for GMM estimation"
		`_pte_clear_eclass'
		`_pte_clear_estimates'
		exit 498
	}
	
	// Report the final support that survives both sample filters and lag checks.
	if "`report'" == "" {
		local N_pre_gmm_excluded = `N_touse' - `N_gmm'
		di as text ""
		di as text "GMM Sample Summary:"
		di as text "  GMM sample size:         " as result %10.0f `N_gmm'
		di as text "  Excluded before GMM:     " as result %10.0f `N_pre_gmm_excluded'
		di as text "  Transition rows in sample:" as result %10.0f `_n_trans'
		di as text "  Stable untreated (D=0):  " as result %10.0f `n_stable_0_filtered'
		di as text "  Stable treated (D=1):    " as result %10.0f `n_stable_1_filtered'
	}

	// The treatdependent path requires a time-trend control.
	// Use an internal name to avoid colliding with user variables.
	capture drop _pte_t
	qui egen double _pte_t = group(`time')
	label variable _pte_t "PTE internal time trend (grouped `time')"
	
	// The treatment-dependent branch bypasses the baseline CLK GMM path and
	// delegates estimation after the shared preprocessing.
	if "`treatdependent'" != "" {
		if "`report'" == "" {
			di as text ""
			di as text "Calling endopolyprodest with treatment interactions..."
			di as text "  Free variables:  `_pte_free_vars'"
			di as text "  State variables: `_pte_state_vars'"
		}
		local _td_pfunc = cond("`pfunc'" != "", "`pfunc'", "cd")
		local _td_controls "_pte_t"
		if "`control'" != "" {
			local _td_controls "`_td_controls' `control'"
			local _td_controls : list uniq _td_controls
		}
		local _td_call_opts "depvar(`lny') free(`_pte_free_vars') state(`_pte_state_vars')"
		local _td_call_opts "`_td_call_opts' proxy(`proxy') control(`_td_controls')"
		local _td_call_opts "`_td_call_opts' endo(`treatment')"
		local _td_call_opts "`_td_call_opts' pfunc(`_td_pfunc') omegapoly(`omegapoly') mid(`_pte_midvar')"
		local _td_call_opts "`_td_call_opts' touse(`touse')"
		if "`report'" == "" {
			local _td_call_opts "`_td_call_opts' verbose"
		}
		
		// Delegate the estimation call plus result validation and e() storage.
		capture noisily _pte_treatdep_call_endopoly, `_td_call_opts'
		if _rc {
			local _pte_treatdep_call_rc = _rc
			`_pte_clear_eclass'
			`_pte_clear_estimates'
			exit `_pte_treatdep_call_rc'
		}
		
		// _pte_treatdep_call_endopoly owns e(); skip the baseline GMM path below.
	}
	else {
	// Generate the fixed stage-1 proxy basis used by the paper and DO code.
	
	if "`free'" != "" & "`proxy'" != "" & "`state'" != "" {
		// The first-stage proxy approximation uses the fixed high-order basis
		// from the paper/DO reference workflow; omegapoly governs only the
		// evolution law and later GMM objects, not the stage-1 basis order.
		local _stage1_poly = 3

		// Build the helper call explicitly so pfunc() and lag generation stay aligned.
		local _polyvar_opts "free(`free') proxy(`proxy') state(`state')"
		if "`pfunc'" != "" {
			local _polyvar_opts "`_polyvar_opts' pfunc(`pfunc')"
		}
		local _polyvar_opts "`_polyvar_opts' poly(`_stage1_poly')"
		if "`genlag'" != "" {
			local _polyvar_opts "`_polyvar_opts' genlag"
		}
		
		// The helper owns the exact naming of basis variables used downstream.
		capture noisily _pte_polyvar, `_polyvar_opts'
		if _rc {
			local _pte_polyvar_rc = _rc
			`_pte_clear_eclass'
			`_pte_clear_estimates'
			exit `_pte_polyvar_rc'
		}
		
		// Cache metadata before the next helper overwrites r().
		local _polyvars   "`r(polyvars)'"
		local _n_polyvars = r(n_polyvars)
		local _pfunc      "`r(pfunc)'"
		local _stage1_poly = r(poly)
		if "`genlag'" != "" {
			local _lagvars   "`r(lagvars)'"
			local _n_lagvars = r(n_lagvars)
		}
	}
	
	// Generate the internal time trend used in the stage-1 controls.
	// _pte_stage1 requires a numeric time-trend control in regression.
	// Generate an internal grouped trend to avoid colliding with user data.
	capture drop _pte_t
	qui egen double _pte_t = group(`time')
	label variable _pte_t "PTE internal time trend (grouped `time')"

	local _pte_stage1_tvars "_pte_t"
	local _pte_stage1_trendby "`industry'"
	if "`ttrendby'" != "" & "`byindustry'" == "" {
		local _pte_stage1_trendby "`ttrendby'"
	}
	local _pte_n_ind = 0
	local _pte_stage1_controls "`control'"
	
	// Pooled estimation expands grouped time into industry-specific trends to
	// mirror the pooled DO regressions; by-industry estimation uses one trend.
	if "`ttrendvars'" != "" & "`byindustry'" == "" {
		local _pte_stage1_tvars "`ttrendvars'"
		local _pte_n_ind : word count `ttrendvars'
	}
	else if "`_pte_stage1_trendby'" != "" & "`byindustry'" == "" {
		tempvar _pte_indgroup
		qui egen long `_pte_indgroup' = group(`_pte_stage1_trendby') if `_pte_active_sample'
		qui levelsof `_pte_indgroup' if `_pte_active_sample', local(_ind_levels)
		local _j = 0
		local _pte_stage1_tvars ""
		foreach _lev of local _ind_levels {
			local ++_j
			capture drop _pte_t`_j'
			qui gen double _pte_t`_j' = _pte_t * (`_pte_indgroup' == `_lev') if `_pte_active_sample'
			local _pte_stage1_tvars "`_pte_stage1_tvars' _pte_t`_j'"
		}
		local _pte_n_ind = `_j'
	}

	if "`control'" != "" & "`_pte_stage1_tvars'" == "_pte_t" {
		local _pte_stage1_controls ""
		foreach _pte_ctrl of local control {
			capture confirm numeric variable `_pte_ctrl'
			if _rc == 0 {
				quietly count if `_pte_active_sample' & ///
					(missing(`_pte_ctrl') | `_pte_ctrl' != _pte_t)
				if r(N) == 0 {
					local _pte_stage1_tvars "`_pte_ctrl'"
				}
				else {
					local _pte_stage1_controls "`_pte_stage1_controls' `_pte_ctrl'"
				}
			}
			else {
				local _pte_stage1_controls "`_pte_stage1_controls' `_pte_ctrl'"
			}
		}
		local _pte_stage1_controls : list uniq _pte_stage1_controls
	}
	
	// Run the first-stage regression on the full active sample. Transition rows
	// are dropped only when moment conditions are formed, not when phi is fit.
	
	if "`lny'" != "" & "`free'" != "" & "`state'" != "" {
		// Default stage 1 to Cobb-Douglas unless the caller explicitly requests translog.
		local _stage1_pfunc = cond("`pfunc'" != "", "`pfunc'", "cd")
		
		// Keep the stage-1 call assembled here so the time-control contract is visible.
		local _stage1_opts "depvar(`lny') pfunc(`_stage1_pfunc')"
		if "`industry'" != "" {
			local _stage1_opts "`_stage1_opts' industry(`industry')"
		}
		if "`byindustry'" != "" {
			local _stage1_opts "`_stage1_opts' byindustry"
		}
		if "`nodiagnose'" != "" {
			local _stage1_opts "`_stage1_opts' nodiagnose"
		}
			if "`strict'" != "" {
				local _stage1_opts "`_stage1_opts' strict"
			}
			if "`legacyfloatphi'" != "" {
				local _stage1_opts "`_stage1_opts' legacyfloatphi"
			}
			local _stage1_opts "`_stage1_opts' tvars(`_pte_stage1_tvars')"
		
		// Stage 1 sees the full active sample; lag admissibility is enforced later.
		local _stage1_opts "`_stage1_opts' touse(`_pte_active_sample')"
		if "`_pte_stage1_controls'" != "" {
			local _stage1_opts "`_stage1_opts' control(`_pte_stage1_controls')"
		}
		
		// phi and stage-1 diagnostics are produced inside the helper.
		capture noisily _pte_stage1, `_stage1_opts'
		if _rc {
			local _pte_stage1_rc = _rc
			`_pte_clear_eclass'
			`_pte_clear_estimates'
			exit `_pte_stage1_rc'
		}
		
		// Preserve stage-1 outputs before later helpers consume r().
		local _r2_stage1     = r(r2_stage1)
		local _n_stage1      = r(n_stage1)
		local _n_poly_vars   = r(n_poly_vars)
		local _n_control_vars = r(n_control_vars)
		local _diag_status   "`r(diag_status)'"
		local _diag_r2       = r(diag_r2)
		local _diag_max_vif  = r(diag_max_vif)
		local _diag_max_corr = r(diag_max_corr)
		local _phi_mean      = r(phi_mean)
		local _phi_sd        = r(phi_sd)
		local _phi_min       = r(phi_min)
		local _phi_max       = r(phi_max)
		matrix _pte_beta_controls = r(beta_controls)
	}
	
	// Diagnostics are computed inside _pte_stage1; only their summary payload is
	// carried forward here.
	
	// Assemble the matrices consumed by the Mata criterion on the stable-state sample.
	// Theorem 3.1 moment conditions:
	//   Eq.(8): E[omega(beta) - h_bar_0(omega_{-1}(beta)) | Z, D=D_{-1}=0] = 0
	//   Eq.(9): E[omega(beta) - h_bar_1(omega_{-1}(beta)) | Z, D=D_{-1}=1] = 0
	
	if "`lny'" != "" & "`free'" != "" & "`state'" != "" {
		// Keep the GMM production-function tag explicit because matrix shape depends on it.
		local _gmm_pfunc = cond("`pfunc'" != "", "`pfunc'", "cd")
		
		// omegapoly governs the productivity-law approximation only; it does not
		// alter the first-stage basis or switch CD into translog.
		local _gmm_omegapoly = `omegapoly'
		
		// Build the matrix-helper call with the exact current/lag support contract.
		local _gmm_mat_opts "phi(phi) lnl(`free') lnk(`state')"
		local _gmm_mat_opts "`_gmm_mat_opts' treatpost(`treatment') mid(`_pte_midvar')"
		local _gmm_mat_opts "`_gmm_mat_opts' t(_pte_t) id(`id') time(`time')"
		local _gmm_mat_opts "`_gmm_mat_opts' prodfunc(`_gmm_pfunc')"
		local _gmm_mat_opts "`_gmm_mat_opts' omegapoly(`_gmm_omegapoly')"
		if "`dopooledz'" != "" {
			local _gmm_mat_opts "`_gmm_mat_opts' dopooledz"
		}
		
		// Lagged observations outside touse() are invalid; lagged transition rows
		// inside touse() remain valid because only the current observation is
		// required to be stable.
		local _gmm_mat_opts "`_gmm_mat_opts' gmmsample(`_pte_active_sample')"
		
		// Translog: pass squared and interaction variables
		if "`_gmm_pfunc'" == "translog" {
			// The translog moment stack requires the current-level quadratic and
			// interaction terms generated by _pte_polyvar.
			capture confirm variable l2
			if !_rc {
				local _gmm_mat_opts "`_gmm_mat_opts' lsq(l2) ksq(k2) lk(l1k1)"
			}
			else {
				// Accept the legacy naming scheme used by some older helper variants.
				capture confirm variable lnl_sq
				if !_rc {
					local _gmm_mat_opts "`_gmm_mat_opts' lsq(lnl_sq) ksq(lnk_sq) lk(lnl_lnk)"
				}
				else {
					di as error "[pte] Translog requires l2, k2, l1k1 variables"
					di as error "  Run _pte_polyvar with pfunc(translog) first"
					`_pte_clear_eclass'
					`_pte_clear_estimates'
					exit 111
				}
			}
		}
		
		// The helper writes the Mata-side objects consumed by the optimizer.
		capture noisily _pte_gmm_matrices, `_gmm_mat_opts'
		if _rc {
			local _pte_gmm_matrices_rc = _rc
			`_pte_clear_eclass'
			`_pte_clear_estimates'
			exit `_pte_gmm_matrices_rc'
		}
		
		// Cache matrix metadata before optimization overwrites r().
		local _N_gmm        = r(N)
		local _N_original    = r(N_original)
		local _N_excluded    = r(N_excluded)
		local _N_first       = r(N_first)
		local _N_mid         = r(N_mid)
		local _n_stable_0_gmm = r(n_stable_0)
		local _n_stable_1_gmm = r(n_stable_1)
		local _cols_X        = r(cols_X)
		local _cols_Z        = r(cols_Z)
		local _cols_OLP      = r(cols_OLP)
		local _cond_ZZ       = r(cond_ZZ)
		local _gmm_do_pooled_z = r(do_pooled_z)
		local _gmm_z_moment_layout "`r(z_moment_layout)'"
		local _gmm_prodfunc  "`r(prodfunc)'"
	}
	
	// Build OLS starting values for the nonlinear optimizer.
	// CD:       e(b)[1, 1..2] = (beta_l, beta_k)
	// Translog: matrix beta0 = e(b)[1, 1..5] = (beta_l, beta_k, beta_ll, beta_kk, beta_lk)
	//
	// After _pte_stage1, e(b) contains polynomial regression coefficients
	// (19+ variables), NOT the simple betas we need.
	// Run a simple OLS to set correct initial values for MODEL_CLK().
	//
	// CD: e(b)[1, 1..2] = (beta_l, beta_k)
	// Translog: matrix beta0 = e(b)[1, 1..5] = (beta_l, beta_k, beta_ll, beta_kk, beta_lk)
	
	if "`lny'" != "" & "`free'" != "" & "`state'" != "" {
		// Match the DO control set so starting values use the same time controls
		// as the first-stage specification.
		if `_pte_n_ind' > 0 & "`byindustry'" == "" {
			// Pooled paper path uses one grouped-time interaction per benchmark group.
			local _ols_controls "`_pte_stage1_tvars'"
		}
		else {
			// By-industry and single-industry pooled runs use one grouped-time trend.
			local _ols_controls "_pte_t"
		}
		if "`control'" != "" {
			local _ols_controls "`_ols_controls' `control'"
			local _ols_controls : list uniq _ols_controls
		}
		
		if "`_gmm_pfunc'" == "translog" {
			// Extract the five translog coefficients in the order expected by MODEL_CLK().
			qui reg `lny' `free' `state' l2 k2 l1k1 `_ols_controls' if `_pte_active_sample'
			matrix beta0 = e(b)[1, 1..5]
		}
		else {
			// MODEL_CLK() reads the leading labor and capital coefficients from e(b).
			qui reg `lny' `free' `state' `_ols_controls' if `_pte_active_sample'
		}
	}
	
	// Run the Mata optimizer. The evolution coefficients are concentrated out by
	// OLS at each beta guess, so only the production-function parameters are
	// searched numerically.
	
	if "`lny'" != "" & "`free'" != "" & "`state'" != "" {
		// Keep optimizer options explicit so multistart and logging stay visible.
			local _gmm_wrap_opts "prodfunc(`_gmm_pfunc') omegapoly(`_gmm_omegapoly')"
			if "`gmminit'" != "" {
				local _gmm_wrap_opts "`_gmm_wrap_opts' init(`gmminit')"
			}
			if "`multistart'" != "" {
				local _gmm_wrap_opts "`_gmm_wrap_opts' multistart"
			}
		if "`report'" != "" {
			local _gmm_wrap_opts "`_gmm_wrap_opts' nolog"
		}
		
		// The wrapper owns the Mata state and returns the converged beta vector.
		capture noisily _pte_gmm_wrapper, `_gmm_wrap_opts'
		if _rc {
			local _pte_gmm_wrapper_rc = _rc
			`_pte_clear_eclass'
			`_pte_clear_estimates'
			exit `_pte_gmm_wrapper_rc'
		}
		
		// Persist the optimizer payload before any later ereturn call.
		local _fval       = r(fval)
		local _converged  = r(converged)
		local _iterations = r(iterations)
		local _cond_OLtOL = r(cond_OLtOL)
		local _rank_OLtOL = r(rank_OLtOL)
		local _xi_mean    = r(xi_mean)
		local _xi_sd      = r(xi_sd)
		local _xi_max_abs = r(xi_max_abs)
		local _gmm_omegapoly_out = r(omegapoly)
		matrix _pte_beta  = r(beta)
		matrix _pte_beta_init = r(beta_init)
		matrix _pte_beta_start_actual = r(beta_start_actual)
		
		// Recover scalars for the omega bridge and downstream reporting.
		if "`_gmm_pfunc'" == "cd" {
			local _beta_l = _pte_beta[1,1]
			local _beta_k = _pte_beta[1,2]
		}
		else {
			local _beta_l  = _pte_beta[1,1]
			local _beta_k  = _pte_beta[1,2]
			local _beta_ll = _pte_beta[1,3]
			local _beta_kk = _pte_beta[1,4]
			local _beta_lk = _pte_beta[1,5]
		}
		
		// Recover realized productivity from phi and the estimated production function.
		// NOTE: Use parentheses around local macros to handle negative values
		//       e.g., - (`_beta_k') avoids Stata parsing "- -0.42" as invalid
		if "`_gmm_pfunc'" == "cd" {
			capture drop omega
			qui gen double omega = phi - (`_beta_l') * `free' - (`_beta_k') * `state' if `_pte_active_sample'
			label variable omega "Implied productivity (omega = phi - X*beta)"
		}
		else {
			// The translog bridge subtracts the full quadratic input component.
			capture drop omega
			qui gen double omega = phi - (`_beta_l') * `free' - (`_beta_k') * `state' ///
				- (`_beta_ll') * l2 - (`_beta_kk') * k2 - (`_beta_lk') * l1k1 if `_pte_active_sample'
			label variable omega "Implied productivity (omega = phi - X*beta)"
		}
	}
	} // end else (standard GMM pipeline)
	
	// Flag paths that bypassed the baseline GMM solver. These delegate
	// estimation to an external command and own e() upon return.
	local _pte_delegated = ("`treatdependent'" != "")

	// ================================================================
	// Rebuild the final GMM estimation sample for e(sample)
	// ================================================================
	// Theorem 3.1 moments are evaluated only on the non-transition sample
	// with valid lagged states/productivity. This must match the support
	// consumed by _pte_gmm_matrices and the Mata GMM criterion.
	tempvar _pte_pf_esample
	local _N_post = `N_touse'
	if !`_pte_delegated' & "`lny'" != "" & "`free'" != "" & "`state'" != "" {
		tempvar _pte_pf_sort _pte_pf_has_gap _pte_pf_delta_probe
		qui gen long `_pte_pf_sort' = _n
		
		// Mirror the same declared-delta gap rule used by _pte_gmm_matrices so
		// the public e(sample) is the exact criterion sample. Only fall back to
		// observed minimum spacing when the current xtset axis differs from the
		// explicit id()/time() contract passed to this run.
		qui sort `id' `time'
		local _pf_tsdelta = `_pte_declared_tsdelta'
		if missing(`_pf_tsdelta') | `_pf_tsdelta' <= 0 {
			qui by `id' (`time'): gen double `_pte_pf_delta_probe' = ///
				`time' - `time'[_n-1] if _n > 1 & !mi(`time', `time'[_n-1])
			qui summarize `_pte_pf_delta_probe' if `_pte_pf_delta_probe' > 0, meanonly
			local _pf_tsdelta = r(min)
		}
		if missing(`_pf_tsdelta') | `_pf_tsdelta' <= 0 {
			local _pf_tsdelta = 1
		}
		local _pf_tsdelta_tol = max(1e-10, abs(`_pf_tsdelta') * 1e-10)
		
		qui sort `id' `time'
		qui gen byte `_pte_pf_esample' = `_pte_active_sample' & (`_pte_midvar' == 0)
		qui by `id' (`time'): gen byte `_pte_pf_has_gap' = ///
			(abs((`time' - `time'[_n-1]) - `_pf_tsdelta') > `_pf_tsdelta_tol') if _n > 1
		qui by `id' (`time'): replace `_pte_pf_has_gap' = 1 if _n == 1
		qui replace `_pte_pf_esample' = 0 if `_pte_pf_has_gap' == 1
		qui replace `_pte_pf_esample' = 0 if _n > 1 & `_pte_active_sample'[_n-1] != 1
		qui replace `_pte_pf_esample' = 0 if ///
			mi(phi) | mi(phi[_n-1]) | ///
			mi(`free') | mi(`free'[_n-1]) | ///
			mi(`state') | mi(`state'[_n-1]) | ///
			mi(`treatment') | mi(`treatment'[_n-1]) | ///
			mi(_pte_t)
		if "`_gmm_pfunc'" == "translog" {
			qui replace `_pte_pf_esample' = 0 if ///
				mi(l2) | mi(l2[_n-1]) | ///
				mi(k2) | mi(k2[_n-1]) | ///
				mi(l1k1) | mi(l1k1[_n-1])
		}
		qui sort `_pte_pf_sort'
		qui count if `_pte_pf_esample'
		local _N_post = r(N)
	}
	else {
		qui gen byte `_pte_pf_esample' = `_pte_active_sample'
	}
	
	// Publish estimation results in e(). ereturn post must come first because
	// it clears any previous e() payload.
	tempname b_post V_post
	if "`treatdependent'" != "" {
		ereturn scalar N_gmm = `N_gmm'
		ereturn scalar omegapoly = `omegapoly'
		ereturn local  prodfunc "`e(pfunc)'"
	}
	else if "`lny'" != "" & "`free'" != "" & "`state'" != "" {
		// Use the beta matrix from GMM optimization
		matrix `b_post' = _pte_beta
		matrix `V_post' = J(colsof(_pte_beta), colsof(_pte_beta), 0)
		// Set column names for ereturn post (requires valid Stata variable names)
		if "`_gmm_pfunc'" == "cd" {
			matrix colnames `b_post' = `free' `state'
		}
		else {
			matrix colnames `b_post' = `free' `state' l2 k2 l1k1
		}
		matrix colnames `V_post' = `: colnames `b_post''
		matrix rownames `V_post' = `: colnames `b_post''
		ereturn post `b_post' `V_post', esample(`_pte_pf_esample') obs(`_N_post')
	}
	else {
		// No estimation performed, just store sample info
		ereturn post, esample(`_pte_pf_esample') obs(`_N_post')
	}

	capture drop _pte_prodfunc_ready
	quietly gen byte _pte_prodfunc_ready = (`_pte_active_sample' != 0 & !missing(`_pte_active_sample'))
	label variable _pte_prodfunc_ready "PTE: production function estimation prodfunc contract ready"
	
	// Transition counts describe the tagging step used to define the stable sample.
	ereturn scalar n_trans      = `_n_trans'
	ereturn scalar n_trans_up   = `_n_trans_up'
	ereturn scalar n_trans_down = `_n_trans_down'
	if !`_pte_delegated' & "`lny'" != "" & "`free'" != "" & "`state'" != "" {
		// Publish stable-count metadata on the true GMM support, matching
		// e(sample) and the sample consumed by the moment-condition helper.
		ereturn scalar n_stable_0 = `_n_stable_0_gmm'
		ereturn scalar n_stable_1 = `_n_stable_1_gmm'
		ereturn scalar n_stable_0_pre_gmm = `_n_stable_0'
		ereturn scalar n_stable_1_pre_gmm = `_n_stable_1'
	}
	else {
		ereturn scalar n_stable_0 = `_n_stable_0'
		ereturn scalar n_stable_1 = `_n_stable_1'
	}
	ereturn scalar n_total      = `_n_total'
	ereturn scalar pct_excluded = `_pct_excluded'
	ereturn scalar n_trans_lag  = `_n_trans_lag'
	
	// Stage-1 diagnostics document the proxy-regression fit that produced phi.
	if "`lny'" != "" & "`free'" != "" & "`state'" != "" & !`_pte_delegated' {
		local _pte_n_beta_controls = colsof(_pte_beta_controls)
		if `_pte_n_beta_controls' == 1 {
			local _pte_beta_t_scalar = _pte_beta_controls[1, 1]
		}
		ereturn scalar r2_stage1     = `_r2_stage1'
		ereturn scalar n_stage1      = `_n_stage1'
		ereturn scalar n_poly_vars   = `_n_poly_vars'
		ereturn scalar n_control_vars = `_n_control_vars'
		ereturn local  diag_status    "`_diag_status'"
		ereturn scalar diag_r2       = `_diag_r2'
		ereturn scalar diag_max_vif  = `_diag_max_vif'
		ereturn scalar diag_max_corr = `_diag_max_corr'
		ereturn scalar phi_mean      = `_phi_mean'
		ereturn scalar phi_sd        = `_phi_sd'
		ereturn matrix beta_controls = _pte_beta_controls
		if `_pte_n_beta_controls' == 1 {
			// Preserve the single-trend scalar used by the paper/DO one-control path.
			ereturn scalar beta_t = `_pte_beta_t_scalar'
		}
	}
	
	// Matrix metadata helps diagnose rank and conditioning problems in the moment stack.
	if "`lny'" != "" & "`free'" != "" & "`state'" != "" & !`_pte_delegated' {
		ereturn scalar N_gmm        = `_N_gmm'
		ereturn scalar N_original   = `_N_original'
		ereturn scalar N_excluded   = `_N_excluded'
		ereturn scalar N_first      = `_N_first'
		ereturn scalar N_mid        = `_N_mid'
		ereturn scalar cols_X       = `_cols_X'
		ereturn scalar cols_Z       = `_cols_Z'
		ereturn scalar cols_OLP     = `_cols_OLP'
		ereturn scalar cond_ZZ      = `_cond_ZZ'
		ereturn scalar do_pooled_z  = `_gmm_do_pooled_z'
		ereturn local  z_moment_layout "`_gmm_z_moment_layout'"
	}
	
	// Optimization metadata describes the converged production-function fit.
	if "`lny'" != "" & "`free'" != "" & "`state'" != "" & !`_pte_delegated' {
		ereturn scalar fval      = `_fval'
		ereturn scalar converged = `_converged'
		ereturn scalar iterations = `_iterations'
		ereturn scalar cond_OLtOL = `_cond_OLtOL'
		ereturn scalar rank_OLtOL = `_rank_OLtOL'
		ereturn scalar xi_mean = `_xi_mean'
		ereturn scalar xi_sd = `_xi_sd'
		ereturn scalar xi_max_abs = `_xi_max_abs'
		ereturn scalar omegapoly = `_gmm_omegapoly'
		ereturn matrix beta_init = _pte_beta_init
		ereturn matrix beta_start_actual = _pte_beta_start_actual
		// beta is already stored via ereturn post above
		ereturn local  prodfunc   "`_gmm_pfunc'"
		ereturn local  pfunc      "`_gmm_pfunc'"
	}
	
	// Echo the caller's variable contract for downstream replay helpers.
	ereturn local cmd "_pte_prodfunc"
	ereturn local treatment "`treatment'"
	ereturn local id "`id'"
	ereturn local time "`time'"
	if "`lny'" != "" {
		ereturn local depvar "`lny'"
	}
	if "`free'" != "" {
		ereturn local free "`free'"
	}
	if "`state'" != "" {
		ereturn local state "`state'"
	}
	if "`proxy'" != "" {
		ereturn local proxy "`proxy'"
	}
	if "`ttrendby'" != "" {
		ereturn local ttrendby "`ttrendby'"
	}
	if "`ttrendvars'" != "" {
		ereturn local ttrendvars "`ttrendvars'"
	}
	
end
