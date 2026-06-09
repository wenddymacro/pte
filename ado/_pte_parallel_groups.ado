*! _pte_parallel_groups.ado
*! Orchestrates parallel or serial execution of bygroup estimation.
*! Detects environment, allocates tasks, dispatches workers, merges results.
*! Falls back gracefully to _pte_bygroup (serial) when parallel is unavailable.

version 14.0
capture program drop _pte_parallel_groups
capture program drop _pte_pgs_clear
program define _pte_pgs_clear
    version 14.0
    // Failure exits must leave no active estimation result. A dummy eclass
    // makes generic e(b)-based consumers treat the failed call as usable.
    capture ereturn clear
end

program define _pte_parallel_groups, eclass
    version 14.0
    
    // Preserve the raw option surface so grouped point execution can
    // distinguish an omitted seed() from an explicit caller seed.
    local _pte_cmdline `"`0'"'
    local _pte_has_seed = regexm(lower(`"`_pte_cmdline'"'), "(^|[ ,])seed[(]")
    
    // =========================================================================
    // 1. Syntax parsing (TASK-002)
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
        POLY(integer 3)                     /// polynomial order
        OMEGApoly(integer 3)                /// evolution polynomial order
        eps0window(integer 0)               /// eps0 window passed to _pte_omega
        NSIM(integer -1)                    /// counterfactual paths
        ATTperiods(integer 4)               /// max ATT periods
        BOOTstrap(integer 0)                /// bootstrap replications
        SEED(integer 123456)                /// random seed
        SEED_boot(integer -1)               /// bootstrap seed
        REPlicate                           /// replication mode
        MIN_obs(integer 100)                /// minimum obs warning
        NOTRIMeps                           /// disable eps0 winsorize
        NOLog                               /// suppress progress
        Nproc(integer 0)                    /// number of processors (0=auto)
        Method(string)                      /// parallel method: auto/parallel_pkg/serial
        Balance(string)                     /// load balance: round_robin/contiguous/weighted
        Timeout(integer 0)                  /// timeout in seconds (0=none)
        BOOTstrap_parallel(integer 0)       /// bootstrap parallel workers (0=serial)
        ]
    local _pte_syntax_rc = _rc
    if `_pte_syntax_rc' != 0 {
        _pte_pgs_clear
        exit `_pte_syntax_rc'
    }
    
    // Dependent variable
    local depvar `varlist'

    // This helper is an eclass producer on success. Clear any prior grouped
    // result after parsing so validation failures do not leak stale e().
    _pte_pgs_clear

    // Grouped parallel execution must preserve the same panel contract as the
    // serial bygroup path. Capture the live xtset metadata once so the
    // master-data bridge can repost it for fresh child sessions.
    capture _xt, trequired
    if _rc != 0 {
        capture ereturn clear
        capture estimates clear
        display as error "_pte_parallel_groups: data must be xtset as panel"
        exit 459
    }
    local _pte_panelvar "`r(ivar)'"
    local _pte_timevar "`r(tvar)'"
    local _pte_xtdelta "`r(tdelta)'"
    local _pte_xtdelta_opt ""
    if "`_pte_xtdelta'" != "" & "`_pte_xtdelta'" != "." & "`_pte_xtdelta'" != "1" {
        local _pte_xtdelta_opt "delta(`_pte_xtdelta')"
    }
    
    // =========================================================================
    // 2. Parameter validation (TASK-003)
    // =========================================================================
    
    // Default production function type
    if "`pfunc'" == "" local pfunc "translog"
    
    // Official grouped benchmark paths use a fixed point-seed law: omitted
    // seed() means ATT simulation runs with 10000, not the serial default
    // 123456. Grouped bootstrap additionally uses a pfunc-specific outer seed
    // when callers omit seed_boot(): 10000 for CD, 20000 for translog.
    if !`_pte_has_seed' {
        local seed = 10000
    }
    if `seed_boot' == -1 {
        if `bootstrap' > 0 & !`_pte_has_seed' {
            if "`pfunc'" == "translog" {
                local seed_boot = 20000
            }
            else {
                local seed_boot = 10000
            }
        }
        else {
            local seed_boot = `seed'
        }
    }
    
    // Default method
    if "`method'" == "" local method "auto"
    
    // Default balance strategy
    if "`balance'" == "" local balance "round_robin"
    
    // Validate nproc
    if `nproc' < 0 {
        capture ereturn clear
        capture estimates clear
        display as error "_pte_parallel_groups: nproc() must be >= 0"
        exit 198
    }
    
    // Validate method
    if !inlist("`method'", "auto", "parallel_pkg", "serial") {
        capture ereturn clear
        capture estimates clear
        display as error "_pte_parallel_groups: method() must be auto, parallel_pkg, or serial"
        exit 198
    }
    
    // Validate balance
    if !inlist("`balance'", "round_robin", "contiguous", "weighted") {
        capture ereturn clear
        capture estimates clear
        display as error "_pte_parallel_groups: balance() must be round_robin, contiguous, or weighted"
        exit 198
    }
    
    // Validate timeout
    if `timeout' < 0 {
        capture ereturn clear
        capture estimates clear
        display as error "_pte_parallel_groups: timeout() must be >= 0"
        exit 198
    }

    local _pte_n_controls : word count `control'

    // Match the grouped serial/bootstrap omission contract before any branch
    // forwards nsim() to _pte_bygroup. Otherwise the syntax default would
    // silently hard-code 100 and downstream helpers could not recover the
    // order-1 single-path law.
    if `nsim' == -1 {
        if `omegapoly' == 1 {
            local nsim = 1
        }
        else {
            local nsim = 100
        }
    }
    
    // =========================================================================
    // 3. Environment detection (TASK-005 ~ 008)
    // =========================================================================
    
    // Call _pte_check_parallel for environment detection
    _pte_check_parallel, quiet
    local is_mp = r(is_mp)
    local processors = r(processors)
    local has_parallel = r(has_parallel)
    local env_method "`r(parallel_method)'"
    local recommended_nproc = r(recommended_nproc)
    
    // Determine effective nproc
    if `nproc' == 0 {
        local nproc_eff = `recommended_nproc'
    }
    else {
        local nproc_eff = min(`nproc', `processors')
    }
    
    // =========================================================================
    // 4. Method selection with graceful degradation (TASK-007, TASK-008)
    // =========================================================================
    
    local use_parallel = 0
    local degrade_reason ""
    
    if "`method'" == "serial" {
        // User explicitly requested serial
        local use_parallel = 0
        local degrade_reason "user_requested"
    }
    else if !`is_mp' {
        // Non-MP Stata: must use serial
        local use_parallel = 0
        local degrade_reason "not_mp"
        if "`nolog'" == "" {
            display as text ///
                "Note: Parallel disabled (Stata IC/SE), using serial execution"
        }
    }
    else if `nproc_eff' <= 1 {
        // Single processor: serial is optimal
        local use_parallel = 0
        local degrade_reason "single_proc"
        if "`nolog'" == "" {
            display as text ///
                "Note: Single processor detected, using serial execution"
        }
    }
    else if "`method'" == "parallel_pkg" | "`method'" == "auto" {
        if `has_parallel' {
            local use_parallel = 1
        }
        else {
            local use_parallel = 0
            local degrade_reason "no_parallel_pkg"
            if "`nolog'" == "" {
                display as text ///
                    "Note: parallel package not installed, using serial execution"
                display as text ///
                    "  Install with: ssc install parallel"
            }
        }
    }

    // Bootstrap inference is implemented in _pte_bygroup. The direct parallel
    // branch currently merges only point-estimate payloads, so route any
    // bootstrap() request through the serial bygroup contract to avoid
    // silently dropping pooled bootstrap SE/CI objects.
    if `use_parallel' & `bootstrap' > 0 {
        local use_parallel = 0
        local degrade_reason "bootstrap_parallel_unavailable"
        if "`nolog'" == "" {
            display as text ///
                "Note: bootstrap()>0 currently uses serial grouped fallback"
        }
    }
    
    // Determine final method string for return
    if `use_parallel' {
        local final_method "parallel_pkg"
    }
    else {
        local final_method "serial"
    }
    
    // =========================================================================
    // 5. Group parsing (TASK-009)
    // =========================================================================
    
    // Mark estimation sample
    marksample touse
    local _pte_current_touse "`touse'"
    
    // Detect variable type
    local byvar_type ""
    capture confirm numeric variable `by'
    if _rc == 0 {
        local byvar_type "numeric"
    }
    else {
        local byvar_type "string"
    }
    
    // Get group list
    if "`byvar_type'" == "numeric" {
        qui levelsof `by' if `_pte_current_touse', local(groups)
    }
    else {
        // Keep compound quotes so embedded spaces remain one group token.
        qui levelsof `by' if `_pte_current_touse', local(groups)
    }
    local n_groups = r(r)
    
    if `n_groups' == 0 {
        capture ereturn clear
        capture estimates clear
        display as error "_pte_parallel_groups: no groups found in variable `by'"
        exit 2000
    }
    
    // Get sample sizes per group for weighted allocation
    tempname N_by
    matrix `N_by' = J(`n_groups', 1, 0)
    local _gi = 0
    foreach grp of local groups {
        local ++_gi
        if "`byvar_type'" == "numeric" {
            qui count if `by' == `grp' & `_pte_current_touse'
        }
        else {
            qui count if `by' == "`grp'" & `_pte_current_touse'
        }
        matrix `N_by'[`_gi', 1] = r(N)
    }
    
    // Cap nproc at n_groups (no point having more workers than groups)
    if `nproc_eff' > `n_groups' {
        local nproc_eff = `n_groups'
    }
    
    // =========================================================================
    // 6. Serial fallback path (TASK-008.3)
    // =========================================================================
    
    if !`use_parallel' {
        // Delegate entirely to _pte_bygroup (serial execution)
        if "`nolog'" == "" {
            display as text ""
            display as text "{hline 60}"
            display as text "PTE Group Estimation (serial mode)"
            display as text "  Groups: `n_groups'  Method: `final_method'"
            if "`degrade_reason'" != "" & "`degrade_reason'" != "user_requested" {
                display as text "  Degraded from parallel: `degrade_reason'"
            }
            display as text "{hline 60}"
        }
        
        // Build option string for _pte_bygroup
        local bygroup_opts "by(`by') free(`free') state(`state')"
        local bygroup_opts "`bygroup_opts' proxy(`proxy') treatment(`treatment')"
        local bygroup_opts "`bygroup_opts' pfunc(`pfunc') poly(`poly')"
        local bygroup_opts "`bygroup_opts' omegapoly(`omegapoly') nsim(`nsim')"
        local bygroup_opts "`bygroup_opts' attperiods(`attperiods')"
        local bygroup_opts "`bygroup_opts' bootstrap(`bootstrap') seed(`seed')"
        local bygroup_opts "`bygroup_opts' seed_boot(`seed_boot')"
        local bygroup_opts "`bygroup_opts' eps0window(`eps0window')"
        local bygroup_opts "`bygroup_opts' min_obs(`min_obs')"
        
        if "`control'" != "" {
            local bygroup_opts "`bygroup_opts' control(`control')"
        }
        if "`replicate'" != "" {
            local bygroup_opts "`bygroup_opts' replicate"
        }
        if "`notrimeps'" != "" {
            local bygroup_opts "`bygroup_opts' notrimeps"
        }
        if "`nolog'" != "" {
            local bygroup_opts "`bygroup_opts' nolog"
        }
        
        // Call serial bygroup
        _pte_bygroup `depvar' if `_pte_current_touse', `bygroup_opts'
        
        // Pass through ereturn values and add parallel metadata
        ereturn local parallel_method = "`final_method'"
        ereturn scalar n_workers = 1
        ereturn scalar speedup = 1
        if "`degrade_reason'" != "" {
            ereturn local degrade_reason = "`degrade_reason'"
        }
        
        capture drop `_pte_current_touse'
        exit
    }
    
    // =========================================================================
    // 7. Task allocation (TASK-010 ~ 013)
    // =========================================================================
    
    // Initialize task lists for each worker
    forvalues w = 1/`nproc_eff' {
        local tasks_`w' ""
        local load_`w' = 0
    }
    
    if "`balance'" == "round_robin" {
        // Round-robin allocation (TASK-010)
        local w = 0
        local _gi = 0
        foreach grp of local groups {
            local ++_gi
            local w = mod(`w', `nproc_eff') + 1
            local tasks_`w' "`tasks_`w'' `grp'"
            local load_`w' = `load_`w'' + `N_by'[`_gi', 1]
        }
    }
    else if "`balance'" == "contiguous" {
        // Contiguous allocation (TASK-011)
        local batch_size = ceil(`n_groups' / `nproc_eff')
        local _gi = 0
        foreach grp of local groups {
            local ++_gi
            local w = ceil(`_gi' / `batch_size')
            if `w' > `nproc_eff' local w = `nproc_eff'
            local tasks_`w' "`tasks_`w'' `grp'"
        }
    }
    else if "`balance'" == "weighted" {
        // Weighted allocation - greedy algorithm (TASK-012)
        // Assign each group to the worker with smallest current load
        local _gi = 0
        foreach grp of local groups {
            local ++_gi
            local grp_n = `N_by'[`_gi', 1]
            
            // Find worker with minimum load
            local min_load = .
            local min_w = 1
            forvalues w = 1/`nproc_eff' {
                if `load_`w'' < `min_load' {
                    local min_load = `load_`w''
                    local min_w = `w'
                }
            }
            
            local tasks_`min_w' "`tasks_`min_w'' `grp'"
            local load_`min_w' = `load_`min_w'' + `grp_n'
        }
    }
    
    // Compute load imbalance (TASK-013)
    local max_load = 0
    local min_load = .
    local sum_load = 0
    forvalues w = 1/`nproc_eff' {
        // Count tasks per worker
        local ntasks_`w' : word count `tasks_`w''
        if `ntasks_`w'' > `max_load' local max_load = `ntasks_`w''
        if `ntasks_`w'' < `min_load' local min_load = `ntasks_`w''
        local sum_load = `sum_load' + `ntasks_`w''
    }
    local mean_load = `sum_load' / `nproc_eff'
    if `mean_load' > 0 {
        local load_imbalance = (`max_load' - `min_load') / `mean_load'
    }
    else {
        local load_imbalance = 0
    }
    
    // Display allocation info
    if "`nolog'" == "" {
        display as text ""
        display as text "{hline 60}"
        display as text "PTE Group Estimation (parallel mode)"
        display as text "  Groups: `n_groups'  Workers: `nproc_eff'"
        display as text "  Method: `final_method'  Balance: `balance'"
        display as text "  Load imbalance: " %5.2f `load_imbalance'
        display as text "{hline 60}"
        forvalues w = 1/`nproc_eff' {
            display as text "  Worker `w': `tasks_`w''"
        }
        display as text "{hline 60}"
    }
    
    // =========================================================================
    // 8. Parallel execution via parallel package (TASK-019 ~ 022)
    // =========================================================================
    
    // Record start time for performance stats
    timer clear 99
    timer on 99
    
    // Probe: time a single group for serial time estimation (TASK-026)
    // The probe is implementation-only. Preserve the caller RNG state so the
    // parallel success path does not leak an extra in-process ATT seed reset.
    local probe_time = .
    local probe_grp : word 1 of `groups'
    local probe_rngstate = c(rngstate)
    timer clear 98
    timer on 98
    
    preserve
    if "`byvar_type'" == "numeric" {
        qui keep if `by' == `probe_grp' & `_pte_current_touse'
    }
    else {
        qui keep if `by' == "`probe_grp'" & `_pte_current_touse'
    }
    
    // Validate panel structure
    capture _xt, trequired
    local idvar = r(ivar)
    local timevar = r(tvar)
    
    capture noisily {
        _pte_prodfunc, treatment(`treatment') id(`idvar') time(`timevar') ///
            lny(`depvar') free(`free') state(`state') ///
            proxy(`proxy') pfunc(`pfunc') poly(`poly') ///
            omegapoly(`omegapoly') noreport replace
        
        _pte_omega, treatment(`treatment') omegapoly(`omegapoly') ///
            eps0window(`eps0window') ///
            `notrimeps' nodiagnose
        
        _pte_att, treatment(`treatment') omegapoly(`omegapoly') ///
            nsim(`nsim') attperiods(`attperiods') ///
            seed(`seed') nodiagnose
    }
    local probe_rc = _rc
    restore
    capture set rngstate `probe_rngstate'

    timer off 98
    qui timer list 98
    if `probe_rc' == 0 {
        local probe_time = r(t98)
    }
    
    // Save master data to tempfile for workers. The marksample-generated
    // touse tempvar is session-local and cannot be used as a cross-process
    // contract; persist an equivalent stable bridge name inside the worker
    // snapshot only, then restore the caller dataset unchanged.
    tempfile _pte_master_data_stub
    local _pte_master_data "`_pte_master_data_stub'_master.dta"
    local _pte_master_touse "pte_pg_touse_bridge"
    preserve
        capture drop `_pte_master_touse'
        quietly gen byte `_pte_master_touse' = (`touse' != 0 & !missing(`touse'))
        capture drop `touse'
        quietly xtset `_pte_panelvar' `_pte_timevar', `_pte_xtdelta_opt'
        qui save "`_pte_master_data'", replace
    restore
    
    // Create temp directory for results
    tempfile _pte_resultbase
    capture confirm number ${PTE_PAR_RUNSEQ}
    if _rc != 0 {
        global PTE_PAR_RUNSEQ 0
    }
    global PTE_PAR_RUNSEQ = ${PTE_PAR_RUNSEQ} + 1
    local _pte_resultbase "`_pte_resultbase'_run${PTE_PAR_RUNSEQ}"
    
    // Set global variables for parallel workers (TASK-020)
    // Note: Stata forbids global names starting with underscore,
    // so we use PTE_PAR_* (uppercase) convention.
    global PTE_PAR_MASTER_DATA "`_pte_master_data'"
    global PTE_PAR_RESULTBASE "`_pte_resultbase'"
    global PTE_PAR_BY "`by'"
    global PTE_PAR_BYVAR_TYPE "`byvar_type'"
    global PTE_PAR_DEPVAR "`depvar'"
    global PTE_PAR_FREE "`free'"
    global PTE_PAR_STATE "`state'"
    global PTE_PAR_PROXY "`proxy'"
    global PTE_PAR_TREATMENT "`treatment'"
    global PTE_PAR_CONTROL "`control'"
    global PTE_PAR_PFUNC "`pfunc'"
    global PTE_PAR_POLY "`poly'"
    global PTE_PAR_OMEGAPOLY "`omegapoly'"
    global PTE_PAR_EPS0WINDOW "`eps0window'"
    global PTE_PAR_NSIM "`nsim'"
    global PTE_PAR_ATTPERIODS "`attperiods'"
    global PTE_PAR_SEED "`seed'"
    global PTE_PAR_NOTRIMEPS "`notrimeps'"
    global PTE_PAR_NPROC "`nproc_eff'"
    global PTE_PAR_N_GROUPS "`n_groups'"
    global PTE_PAR_GROUPS "`groups'"
    global PTE_PAR_PANELVAR "`_pte_panelvar'"
    global PTE_PAR_TIMEVAR "`_pte_timevar'"
    global PTE_PAR_XTDELTA "`_pte_xtdelta'"
    global PTE_PAR_TOUSEVAR "`_pte_master_touse'"
    global PTE_PAR_RUNSEQ "${PTE_PAR_RUNSEQ}"

    // Keep grouped parallel launch aligned with the other parallel helper on
    // macOS app-bundle installs, where parallel's legacy auto-probe can miss
    // the actual StataMP executable path.
    local _pte_parallel_statapath ""
    capture confirm file "/Applications/Stata/StataMP.app/Contents/MacOS/stata-mp"
    if _rc == 0 {
        local _pte_parallel_statapath "/Applications/Stata/StataMP.app/Contents/MacOS/stata-mp"
    }
    else {
        capture confirm file "/Applications/Stata/StataMP.app/Contents/MacOS/StataMP"
        if _rc == 0 {
            local _pte_parallel_statapath "/Applications/Stata/StataMP.app/Contents/MacOS/StataMP"
        }
    }
    
    // Set per-worker task lists
    forvalues w = 1/`nproc_eff' {
        global PTE_PAR_TASKS_`w' "`tasks_`w''"
    }
    
    // Generate temporary worker do-file (TASK-019)
    // The parallel package runs this do-file in each child instance.
    // Each instance gets $pll_instance (1..N) from the parallel package.
    // The do-file calls _pte_group_worker which reads globals.
    tempfile _pte_worker_dofile
    local worker_dofile "`_pte_worker_dofile'.do"
    
    // Write worker do-file content
    tempname _wfh
    file open `_wfh' using "`worker_dofile'", write replace
    file write `_wfh' "* Auto-generated worker do-file for parallel execution" _n
    file write `_wfh' "version 14.0" _n
    file write `_wfh' "capture noisily _pte_group_worker" _n
    file write `_wfh' "if _rc != 0 {" _n
    file write `_wfh' "    exit _rc" _n
    file write `_wfh' "}" _n
    file close `_wfh'
    
    global PTE_PAR_WORKER_DOFILE "`worker_dofile'"
    
    // parallel exports loaded program definitions, not bare ado names that
    // only exist on disk. Fresh sessions therefore need an explicit preload
    // step so grouped workers can reproduce the serial/002/003 chain.
    local _pte_worker_programs "_pte_group_worker _pte_prodfunc _pte_omega _pte_att"
    foreach prog of local _pte_worker_programs {
        capture program list `prog'
        if _rc == 0 {
            continue
        }
        capture findfile `prog'.ado
        if _rc != 0 {
            di as error "[pte] Error: worker helper `prog'.ado not found on adopath"
            exit 111
        }
        local _pte_progfile `"`r(fn)'"'
        quietly do `"`_pte_progfile'"'
        capture program list `prog'
        if _rc != 0 {
            di as error "[pte] Error: failed to preload worker helper `prog'"
            exit 111
        }
    }
    
    // Execute via parallel package (TASK-019)
    capture noisily {
        if "`_pte_parallel_statapath'" != "" {
            parallel setclusters `nproc_eff', force ///
                statapath(`_pte_parallel_statapath')
        }
        else {
            parallel setclusters `nproc_eff', force
        }
        parallel do "`worker_dofile'", nodata ///
            programs(`_pte_worker_programs') ///
            mata
    }
    local parallel_rc = _rc
    
    // If parallel execution failed, fall back to serial
    if `parallel_rc' != 0 {
        if "`nolog'" == "" {
            display as error ///
                "Parallel execution failed (rc=`parallel_rc'), falling back to serial"
        }
        
        // Clean up globals
        _pte_parallel_groups_cleanup
        
        // Fall back to serial _pte_bygroup
        local bygroup_opts "by(`by') free(`free') state(`state')"
        local bygroup_opts "`bygroup_opts' proxy(`proxy') treatment(`treatment')"
        local bygroup_opts "`bygroup_opts' pfunc(`pfunc') poly(`poly')"
        local bygroup_opts "`bygroup_opts' omegapoly(`omegapoly') nsim(`nsim')"
        local bygroup_opts "`bygroup_opts' attperiods(`attperiods')"
        local bygroup_opts "`bygroup_opts' bootstrap(`bootstrap') seed(`seed')"
        local bygroup_opts "`bygroup_opts' seed_boot(`seed_boot')"
        local bygroup_opts "`bygroup_opts' eps0window(`eps0window')"
        local bygroup_opts "`bygroup_opts' min_obs(`min_obs')"
        
        if "`control'" != "" {
            local bygroup_opts "`bygroup_opts' control(`control')"
        }
        if "`replicate'" != "" {
            local bygroup_opts "`bygroup_opts' replicate"
        }
        if "`notrimeps'" != "" {
            local bygroup_opts "`bygroup_opts' notrimeps"
        }
        if "`nolog'" != "" {
            local bygroup_opts "`bygroup_opts' nolog"
        }
        
        _pte_bygroup `depvar' if `_pte_current_touse', `bygroup_opts'
        
        ereturn local parallel_method = "serial"
        ereturn local degrade_reason = "parallel_failed"
        ereturn scalar n_workers = 1
        ereturn scalar speedup = 1
        
        capture drop `_pte_current_touse'
        exit
    }
    
    // =========================================================================
    // 9. Result merging (TASK-023 ~ 025)
    // =========================================================================
    
    // Determine parameter dimensions
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
    local n_rho = `omegapoly' + 1
    local n_att = `attperiods' + 2
    
    // Initialize result matrices
    tempname BETA RHO SIGMA ATT_by N_OBS N_FIRMS
    matrix `BETA'    = J(`n_groups', `n_beta', .)
    matrix `RHO'     = J(`n_groups', `n_rho', .)
    matrix `SIGMA'   = J(`n_groups', 1, .)
    matrix `ATT_by'  = J(`n_groups', `n_att', .)
    matrix `N_OBS'   = J(`n_groups', 1, .)
    matrix `N_FIRMS' = J(`n_groups', 1, .)
    
    // Row names
    local rownames ""
    forvalues i = 1/`n_groups' {
        local rownames "`rownames' grp_`i'"
    }
    matrix rownames `BETA'    = `rownames'
    matrix rownames `RHO'     = `rownames'
    matrix rownames `SIGMA'   = `rownames'
    matrix rownames `ATT_by'  = `rownames'
    matrix rownames `N_OBS'   = `rownames'
    matrix rownames `N_FIRMS' = `rownames'
    
    // Column names for BETA
    matrix colnames `BETA' = `beta_colnames'
    
    // Column names for RHO
    local rho_colnames ""
    forvalues j = 0/`omegapoly' {
        local rho_colnames "`rho_colnames' rho_`j'"
    }
    matrix colnames `RHO' = `rho_colnames'
    matrix colnames `SIGMA' = sigma_eps
    
    // Column names for ATT
    local att_colnames ""
    forvalues l = 0/`attperiods' {
        local att_colnames "`att_colnames' ATT_`l'"
    }
    local att_colnames "`att_colnames' ATT_avg"
    matrix colnames `ATT_by' = `att_colnames'
    matrix colnames `N_OBS'  = N_obs
    matrix colnames `N_FIRMS' = N_firms
    
    // Collect per-group results from worker output files (TASK-025)
    local n_failed = 0
    local first_fail_rc = 0
    local payload_groups ""
    local _gi = 0
    foreach grp of local groups {
        local ++_gi

        capture confirm file "`_pte_resultbase'_status_`_gi'.dta"
        if _rc != 0 {
            local ++n_failed
            if `first_fail_rc' == 0 {
                local first_fail_rc = 498
            }
            if "`nolog'" == "" {
                display as text ///
                    "Warning: Missing current-run status for group `grp' (index `_gi')"
            }
            continue
        }

        preserve
        qui use "`_pte_resultbase'_status_`_gi'.dta", clear
        qui summarize _pte_success, meanonly
        local _group_success = (r(N) > 0 & r(mean) == 1)
        qui summarize _pte_rc, meanonly
        local _group_rc = r(mean)
        restore

        if !`_group_success' {
            local ++n_failed
            if `first_fail_rc' == 0 & `_group_rc' != . & `_group_rc' > 0 {
                local first_fail_rc = `_group_rc'
            }
            if "`nolog'" == "" {
                display as text ///
                    "Warning: Current run failed for group `grp' (index `_gi')"
            }
            continue
        }

        // Try to load group result file
        capture confirm file "`_pte_resultbase'_params_`_gi'.dta"
        if _rc == 0 {
            local payload_groups "`payload_groups' `_gi'"
            preserve
            qui use "`_pte_resultbase'_params_`_gi'.dta", clear
            
            // Extract beta
            forvalues j = 1/`n_beta' {
                capture {
                    qui sum _pte_beta_`j'
                    matrix `BETA'[`_gi', `j'] = r(mean)
                }
            }
            
            // Extract rho
            forvalues j = 1/`n_rho' {
                capture {
                    qui sum _pte_rho_`j'
                    matrix `RHO'[`_gi', `j'] = r(mean)
                }
            }
            
            // Extract sigma
            capture {
                qui sum _pte_sigma
                matrix `SIGMA'[`_gi', 1] = r(mean)
            }
            
            // Extract ATT
            forvalues j = 1/`n_att' {
                capture {
                    qui sum _pte_att_`j'
                    matrix `ATT_by'[`_gi', `j'] = r(mean)
                }
            }
            
            // Extract sample info
            capture {
                qui sum _pte_nobs
                matrix `N_OBS'[`_gi', 1] = r(mean)
            }
            capture {
                qui sum _pte_nfirms
                matrix `N_FIRMS'[`_gi', 1] = r(mean)
            }
            
            restore
        }
        else {
            _pte_parallel_groups_cleanup
            _pte_pgs_clear
            display as error ///
                "_pte_parallel_groups: current-run params payload missing for successful group index `_gi'"
            display as error ///
                "Parallel grouped estimation cannot post public results when a successful group lacks branch coefficients"
            capture drop `_pte_current_touse'
            exit 498
        }
    }

    // Parallel grouped estimation is only defined when at least one group
    // produced a current-run payload. Mirror the serial bygroup contract:
    // all-group failure must abort instead of posting an empty grouped result
    // bundle or leaving stale e() visible to downstream consumers.
    if `n_failed' == `n_groups' {
        _pte_parallel_groups_cleanup
        if `first_fail_rc' == 0 {
            local first_fail_rc = 498
        }
        _pte_pgs_clear
        display as error ///
            "_pte_parallel_groups: all groups failed; no grouped estimation results can be posted"
        display as error ///
            "Fix the by()/industry() split or estimation support before rerunning grouped pte"
        capture drop `_pte_current_touse'
        exit `first_fail_rc'
    }
    
    // Merge firm-level TT data and compute pooled ATT (TASK-023, TASK-024)
    tempname ATT_pool ATT_pool_trim ATT_pool_raw ATT_sd ATT_N
    matrix `ATT_pool' = J(1, `n_att', .)
    matrix `ATT_pool_trim' = J(1, `n_att', .)
    matrix `ATT_pool_raw' = J(1, `n_att', .)
    matrix `ATT_sd'   = J(1, `n_att', .)
    matrix `ATT_N'    = J(1, `n_att', 0)
    local has_att_pool_trim = 0
    local has_att_pool_raw = 0
    local tt_missing_group = 0

    foreach _gi of local payload_groups {
        capture confirm file "`_pte_resultbase'_tt_`_gi'.dta"
        if _rc != 0 {
            local tt_missing_group = `_gi'
            continue, break
        }
    }

    if `tt_missing_group' > 0 {
        _pte_parallel_groups_cleanup
        _pte_pgs_clear
        display as error ///
            "_pte_parallel_groups: current-run TT payload missing for successful group index `tt_missing_group'"
        display as error ///
            "Parallel grouped ATT cannot post pooled results when a successful group lacks TT data"
        capture drop `_pte_current_touse'
        exit 498
    }
    
    preserve
    local first_found = 0
    foreach _gi of local payload_groups {
        if `first_found' == 0 {
            qui use "`_pte_resultbase'_tt_`_gi'.dta", clear
            local first_found = 1
        }
        else {
            capture qui append using ///
                "`_pte_resultbase'_tt_`_gi'.dta", force
        }
    }
    
    if `first_found' {
        capture confirm variable TT_mean_trim
        local has_att_pool_trim = (_rc == 0)
        capture confirm variable TT_mean_raw
        local has_att_pool_raw = (_rc == 0)

        // Compute pooled ATT by relative time
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
        }
        
        // ATT_avg
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
    }
    restore
    
    matrix colnames `ATT_pool' = `att_colnames'
    if `has_att_pool_trim' matrix colnames `ATT_pool_trim' = `att_colnames'
    if `has_att_pool_raw' matrix colnames `ATT_pool_raw' = `att_colnames'
    matrix colnames `ATT_sd'   = `att_colnames'
    matrix colnames `ATT_N'    = `att_colnames'

    // =========================================================================
    // 10. Performance statistics (TASK-026)
    // =========================================================================
    
    timer off 99
    qui timer list 99
    local time_parallel = r(t99)
    
    // Estimate serial time from probe
    local time_serial_est = .
    if `probe_time' != . & `probe_time' > 0 {
        local time_serial_est = `probe_time' * `n_groups'
    }
    
    // Compute speedup ratio
    local speedup = .
    if `time_serial_est' != . & `time_parallel' > 0 {
        local speedup = `time_serial_est' / `time_parallel'
    }
    
    // Display performance summary
    if "`nolog'" == "" {
        display as text ""
        display as text "{hline 60}"
        display as text "Performance Summary"
        display as text "{hline 60}"
        display as text "  Parallel time:     " %8.1f `time_parallel' " sec"
        if `time_serial_est' != . {
            display as text "  Serial estimate:   " ///
                %8.1f `time_serial_est' " sec"
            display as text "  Speedup:           " %8.2f `speedup' "x"
        }
        else {
            display as text "  Serial estimate:   (probe failed)"
            display as text "  Speedup:           (unavailable)"
        }
        display as text "  Groups completed:  " ///
            (`n_groups' - `n_failed') " / `n_groups'"
        if `n_failed' > 0 {
            display as text "  Groups failed:     `n_failed'"
        }
        display as text "{hline 60}"
    }
    
    // =========================================================================
    // 11. ereturn values (TASK-004)
    // =========================================================================
    
    ereturn clear
    
    // Core result matrices
    ereturn matrix att_pool   = `ATT_pool'
    if `has_att_pool_trim' {
        ereturn matrix att_pool_trim = `ATT_pool_trim'
    }
    if `has_att_pool_raw' {
        ereturn matrix att_pool_raw = `ATT_pool_raw'
    }
    ereturn matrix att_sd     = `ATT_sd'
    ereturn matrix att_N      = `ATT_N'
    ereturn matrix att_by     = `ATT_by'
    ereturn matrix b_by       = `BETA'
    ereturn matrix rho_by     = `RHO'
    ereturn matrix sigma_by   = `SIGMA'
    ereturn matrix N_by       = `N_OBS'
    ereturn matrix N_firms_by = `N_FIRMS'
    
    // Scalars
    ereturn scalar n_groups    = `n_groups'
    ereturn scalar omegapoly   = `omegapoly'
    ereturn scalar attperiods  = `attperiods'
    ereturn scalar attperiods_max = `attperiods'
    ereturn scalar eps0window  = `eps0window'
    ereturn scalar nsim        = `nsim'
    ereturn scalar bootstrap   = `bootstrap'
    ereturn scalar seed        = `seed'
    ereturn scalar n_workers   = `nproc_eff'
    ereturn scalar n_failed    = `n_failed'
    
    // Performance scalars
    ereturn scalar time_parallel    = `time_parallel'
    ereturn scalar time_serial_est  = `time_serial_est'
    ereturn scalar speedup          = `speedup'
    ereturn scalar load_imbalance   = `load_imbalance'
    
    // Macros
    ereturn local parallel_method  "`final_method'"
    ereturn local balance          "`balance'"
    ereturn local by               "`by'"
    ereturn local groups           "`groups'"
    ereturn local depvar           "`depvar'"
    ereturn local pfunc            "`pfunc'"
    ereturn local cmd              "_pte_parallel_groups"
    if "`degrade_reason'" != "" {
        ereturn local degrade_reason "`degrade_reason'"
    }
    
    // =========================================================================
    // 12. Global macro cleanup (TASK-022)
    // =========================================================================
    
    capture drop `_pte_current_touse'
    _pte_parallel_groups_cleanup
    
end
