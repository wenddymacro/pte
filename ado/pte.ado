*! pte.ado
*! Public entry point for PTE estimation and post-estimation setup.
*!
*! Authors: Xuanyu Cai (xuanyuCAI@outlook.com)
*!          Wenli Xu (wlxu@cityu.edu.mo)
*!          City University of Macau
*!
*! Validates the public interface, runs the production-function and
*! productivity-recovery pipeline, and optionally computes ATT with
*! bootstrap inference.

version 14.0
capture program drop pte
program define pte, eclass sortpreserve
    version 14.0

    // Replay the last pte estimation without reparsing the full estimator
    // syntax. This preserves the standard Stata estimation-command contract.
    if replay() {
        if "`e(cmd)'" != "pte" {
            error 301
        }

        syntax [, Level(string) NOLOg]

        if `"`level'"' == "" {
            capture local level = e(level)
            if _rc != 0 | missing(`level') {
                local level = c(level)
            }
        }
        else {
            local replay_level = real(`"`level'"')
            if missing(`replay_level') {
                di as error "option level() incorrectly specified"
                exit 198
            }
            if `replay_level' < 10 | `replay_level' > 99 {
                di as error "level() must be between 10 and 99"
                exit 198
            }
            local level = `replay_level'
        }

        local replay_noatt ""
        capture scalar _pte_replay_noatt = e(noatt)
        if _rc == 0 & _pte_replay_noatt == 1 {
            local replay_noatt "noatt"
        }
        capture scalar drop _pte_replay_noatt

        // Replay should validate only the payload consumed by the active
        // display branch. Live bygroup replay can be driven either by grouped
        // ATT payloads or, on noatt runs, by the grouped untreated-law
        // matrices. Those paths must not be rejected for lacking serial rho_1.
        local replay_by ""
        capture local replay_by = e(by)
        if _rc == 0 & `"`replay_by'"' == "." {
            local replay_by ""
        }
        local replay_groups ""
        capture local replay_groups = e(groups)
        if _rc == 0 & `"`replay_groups'"' == "." {
            local replay_groups ""
        }
        quietly _pte_has_grouped_replay_state
        local replay_has_grouped_state = r(has_grouped_replay)
        local replay_grouped_payloads `"`r(grouped_payloads)'"'
        if `replay_has_grouped_state' & `"`replay_by'"' == "" {
            di as error "pte replay requires e(by) when grouped replay payloads are active"
            if `"`replay_groups'"' != "" {
                di as error "Current e() results still carry grouped replay output for e(groups)=`replay_groups'."
            }
            else {
                di as error "Current e() results still carry grouped replay output, but grouped routing metadata are incomplete."
            }
            if `"`replay_grouped_payloads'"' != "" {
                di as error "Detected grouped payload(s): `macval(replay_grouped_payloads)'"
            }
            di as error "Replay would otherwise collapse grouped heterogeneity onto the pooled ATT display path."
            exit 198
        }
        local replay_live_bygroup = 0
        if `"`replay_by'"' != "" {
            capture confirm matrix e(att_by)
            if _rc == 0 local replay_live_bygroup = 1
            capture confirm matrix e(att_mean_pool)
            if _rc == 0 local replay_live_bygroup = 1
            capture confirm matrix e(rho_by)
            if _rc == 0 local replay_live_bygroup = 1
        }

        // Serial and legacy grouped ATT replay still consume the treated-law
        // matrix in the evolution block unless the stored Stage-2 state
        // explicitly says only h_bar_0 was identified. noatt replay does not
        // enter the ATT display branch and _pte_display_evolution already
        // degrades safely when e(rho_1) is absent, so bare noatt replay must
        // not be rejected here.
        if !`replay_live_bygroup' & "`replay_noatt'" == "" {
            capture matrix list e(rho_1)
            if _rc != 0 {
                capture scalar _pte_replay_lag_supported = e(lag_treated_supported)
                if _rc != 0 | _pte_replay_lag_supported != 0 {
                    di as error "pte replay requires e(rho_1)"
                    exit 301
                }
            }
            capture scalar drop _pte_replay_lag_supported
        }

        // Replay has no progress phase, so nolog must not suppress the final
        // results summary. Keep parsing it for syntax compatibility only.
        _pte_display, `replay_noatt' level(`level')
        exit
    }

    // Some late public-contract helpers run after the final repost. If one of
    // those helpers fails, the failed rerun must not overwrite the last
    // successful pte replay state.
    tempname _pte_prev_est
    local _pte_has_prev_est = 0
    capture local _pte_prev_cmd = e(cmd)
    if _rc == 0 & `"`_pte_prev_cmd'"' == "pte" {
        capture estimates store `_pte_prev_est', copy
        if _rc == 0 {
            local _pte_has_prev_est = 1
        }
    }

    // Preserve the last successful pte result until a new public e() bundle
    // is ready to replace it. Failed reruns must not destroy replayable state
    // during syntax or parameter validation.

    // Preserve the raw command line so alias resolution can distinguish an
    // explicit omegapoly(3) request from the syntax default.
    local _pte_cmdline `"`0'"'
    local _pte_depvar_literal ""
    gettoken _pte_depvar_literal _pte_cmdrest : _pte_cmdline, parse(" ,") quotes
    local _pte_depvar_literal = lower(strtrim(`"`_pte_depvar_literal'"'))
    foreach _pte_input_opt in free state proxy by {
        local _pte_`_pte_input_opt'_literal ""
        if regexm(lower(`"`_pte_cmdline'"'), ///
            "(^|[ ,])`_pte_input_opt'[ ]*[(]([^)]*)[)]") {
            local _pte_`_pte_input_opt'_literal `"`=regexs(2)'"'
            local _pte_`_pte_input_opt'_literal = ///
                lower(strtrim(`"`_pte_`_pte_input_opt'_literal'"'))
        }
    }
    // control() is parsed by Stata under the documented minimum
    // abbreviation cont(). The raw scanner must recognize those legal
    // spellings so option-name abbreviation cannot bypass the exact-name
    // guard for control variables.
    local _pte_control_literal ""
    if regexm(lower(`"`_pte_cmdline'"'), ///
        "(^|[ ,])(control|contro|contr|cont)[ ]*[(]([^)]*)[)]") {
        local _pte_control_literal `"`=regexs(3)'"'
        local _pte_control_literal = ///
            lower(strtrim(`"`_pte_control_literal'"'))
    }
    // industry() is parsed by Stata under the documented minimum
    // abbreviation ind(). The raw scanner must recognize every legal
    // abbreviation from ind() through industry() so option-name abbreviation
    // cannot bypass the exact-name guard for grouped estimation.
    local _pte_industry_literal ""
    if regexm(lower(`"`_pte_cmdline'"'), ///
        "(^|[ ,])(industry|industr|indust|indus|indu|ind)[ ]*[(]([^)]*)[)]") {
        local _pte_industry_literal `"`=regexs(3)'"'
        local _pte_industry_literal = ///
            lower(strtrim(`"`_pte_industry_literal'"'))
    }
    local _pte_cohort_literal ""
    if regexm(lower(`"`_pte_cmdline'"'), ///
        "(^|[ ,])(cohort|cohor|coho|coh)[ ]*[(]([^)]*)[)]") {
        local _pte_cohort_literal `"`=regexs(3)'"'
        local _pte_cohort_literal = ///
            lower(strtrim(`"`_pte_cohort_literal'"'))
    }
    local _pte_optscan `"`_pte_cmdline'"'
    local _pte_q1 = strpos(`"`_pte_optscan'"', char(34))
    while `_pte_q1' > 0 {
        local _pte_q2 = strpos(substr(`"`_pte_optscan'"', `=`_pte_q1' + 1', .), char(34))
        if `_pte_q2' <= 0 {
            continue, break
        }
        local _pte_q2 = `_pte_q1' + `_pte_q2'
        local _pte_optscan = substr(`"`_pte_optscan'"', 1, `=`_pte_q1' - 1') + ///
            substr(`"`_pte_optscan'"', `=`_pte_q2' + 1', .)
        local _pte_q1 = strpos(`"`_pte_optscan'"', char(34))
    }
    local _pte_has_omegapoly = regexm(lower(`"`_pte_optscan'"'), "(^|[ ,])omegapoly[ ]*[(]")
    local _pte_has_poly = regexm(lower(`"`_pte_optscan'"'), "(^|[ ,])poly[ ]*[(]")
    // attperiods() shares the "att" prefix with attnorm, so Stata accepts
    // the legal disambiguating spellings attp(), attpe(), ..., attperiods().
    // replicate(table1) must treat any of those explicit spellings as an
    // explicit attperiods() request; otherwise the benchmark preset can
    // silently override a caller-specified horizon.
    local _pte_has_attperiods = regexm(lower(`"`_pte_optscan'"'), ///
        "(^|[ ,])(attperiods|attperiod|attperio|attperi|attper|attpe|attp)[ ]*[(]")
    local _pte_has_seed = regexm(lower(`"`_pte_optscan'"'), "(^|[ ,])seed[ ]*[(]")
    local _pte_has_nsim = regexm(lower(`"`_pte_optscan'"'), "(^|[ ,])nsim[ ]*[(]")
    local _pte_has_eps0window = regexm(lower(`"`_pte_optscan'"'), "(^|[ ,])eps0window[ ]*[(]")
    // bootstrap()/reps() share 0 as the public "no bootstrap" value, while
    // syntax also uses 0 as the omission default. The parser must therefore
    // track both raw tokens separately so an explicit bootstrap(0) or reps(0)
    // request is not swallowed as omission during alias normalization.
    local _pte_has_bootstrap = regexm(lower(`"`_pte_optscan'"'), ///
        "(^|[ ,])(bootstrap|bootstra|bootstr|bootst|boots|boot)[ ]*[(]")
    local _pte_has_reps = regexm(lower(`"`_pte_optscan'"'), "(^|[ ,])reps[ ]*[(]")
    // processors() uses -1 as the internal omission sentinel, so the public
    // parser must separately track whether the caller explicitly supplied the
    // option under any legal proc... abbreviation.
    local _pte_has_processors = regexm(lower(`"`_pte_optscan'"'), ///
        "(^|[ ,])(processors|processor|processo|process|proces|proce|proc)[ ]*[(]")

    // Resolve the public syntax once so every downstream check sees the same
    // canonical option state.
    syntax varlist(numeric min=1 max=1) [if] [in], ///
        TREATment(name) ///
        FREE(varlist numeric min=1) ///
        STATE(varlist numeric min=1) ///
        PROXY(varlist numeric min=1) ///
        [CONTrol(varlist numeric) ///
         BY(varname) ///
         PFUNC(string) ///
         OMEGAPOLY(integer 3) ///
         BOOTstrap(integer 0) ///
         TRANSlog ///
         POLY(string) ///
         REPS(integer 0) ///
         ATTperiods(integer 4) ///
         NSIM(integer -1) ///
         SEED(integer -1) ///
         eps0window(integer 0) ///
         NOATT ///
         NOLOg ///
         Level(cilevel) ///
         REPlicate(string) ///
         VERBose ///
         NOTRIMeps ///
         NODIAGnose ///
         SAVing(string) ///
         NOParallel ///
         PROCessors(integer -1) ///
         NONABsorbing ///
         COUNTERfactual ///
         COHort(varname) ///
         INDustry(varname) ///
         BYINDustry ///
         TREATDEPendent ///
         LAGperiods(integer 0) ///
         TARGETgroup(name) ///
         PERSISTperiods(integer 0) ///
         SWITCHdirection(string) ///
         NORMalize(string) ///
         ATTnorm]

    // Keep the outcome name under a stable local before option rewriting.
    local depvar `varlist'

    // Preserve the literal treatment() token until an exact-name check.
    capture confirm variable `treatment', exact
    if _rc != 0 {
        _pte_error, errcode(111) ///
            msg("variable `treatment' not found") ///
            suggestion("Specify the exact treatment variable name in treatment()")
    }
    capture confirm numeric variable `treatment'
    if _rc != 0 {
        _pte_error, errcode(198) ///
            msg("treatment() variable '`treatment'' must be numeric") ///
            suggestion("Convert `treatment' to a numeric 0/1 treatment indicator before running pte")
    }
    quietly count if !missing(`treatment')
    if r(N) == 0 {
        _pte_error, errcode(416) ///
            msg("treatment() is all missing") ///
            suggestion("treatment() must contain at least one nonmissing 0/1 observation")
    }

    // Resolve compatibility aliases first so downstream validation sees one
    // canonical option set.
    if "`pfunc'" != "" {
        local pfunc = lower(strtrim("`pfunc'"))
    }
    if "`translog'" != "" {
        if "`pfunc'" != "" & "`pfunc'" != "translog" {
            _pte_error, errcode(198) ///
                msg("Cannot specify both translog and pfunc(`pfunc')") ///
                suggestion("Use either translog flag or pfunc(translog), not both with different values")
        }
        local pfunc "translog"
    }

    // Resolve the evolution-order aliases before applying defaults so we can
    // distinguish omitted options from explicit omegapoly(3).
    if "`poly'" != "" {
        local poly_num = real("`poly'")
        if missing(`poly_num') | `poly_num' != floor(`poly_num') {
            _pte_error, errcode(198) ///
                msg("poly() must be an integer between 1 and 4") ///
                suggestion("Use poly(1), poly(2), poly(3), or poly(4)")
        }
        local poly = `poly_num'
        if `_pte_has_omegapoly' & `omegapoly' != `poly' {
            _pte_error, errcode(198) ///
                msg("Cannot specify both poly(`poly') and omegapoly(`omegapoly')") ///
                suggestion("Use omegapoly() for evolution polynomial order")
        }
        local omegapoly = `poly'
    }
    local poly = `omegapoly'

    // reps() is a bootstrap alias for older calling conventions. Once either
    // spelling is explicitly present, conflicting explicit counts must fail
    // closed even if one side happens to be 0.
    if `_pte_has_reps' {
        if `_pte_has_bootstrap' & `bootstrap' != `reps' {
            _pte_error, errcode(198) ///
                msg("Cannot specify both reps(`reps') and bootstrap(`bootstrap')") ///
                suggestion("Use bootstrap() for number of bootstrap replications")
        }
        local bootstrap = `reps'
    }

    // Grouped public routes must bind to the exact grouping variable named by
    // the caller. Silent abbreviation fallback would reroute grouped ATT and
    // untreated-law objects to the wrong industry or group split.
    if `"`_pte_by_literal'"' != "" {
        local _pte_by_resolved = lower(strtrim(`"`by'"'))
        if `"`_pte_by_literal'"' != `"`_pte_by_resolved'"' {
            _pte_error, errcode(111) ///
                msg("variable `_pte_by_literal' not found") ///
                suggestion("Specify the exact grouping variable name in by()")
        }
    }
    if `"`_pte_industry_literal'"' != "" {
        local _pte_industry_resolved = lower(strtrim(`"`industry'"'))
        if `"`_pte_industry_literal'"' != `"`_pte_industry_resolved'"' {
            _pte_error, errcode(111) ///
                msg("variable `_pte_industry_literal' not found") ///
                suggestion("Specify the exact grouping variable name in industry()")
        }
    }
    // Normalize benchmark grouping options before branch selection.
    if "`by'" != "" & "`industry'" != "" & "`by'" != "`industry'" {
        _pte_error, errcode(198) ///
            msg("by(`by') conflicts with industry(`industry')") ///
            suggestion("Specify only one grouping variable, or make by() and industry() identical")
    }
    if "`byindustry'" != "" & "`by'" == "" & "`industry'" == "" {
        _pte_error, errcode(198) ///
            msg("byindustry requires industry() or by()") ///
            suggestion("Use industry(varname) byindustry, or use by(varname) alone")
    }
    local benchmark_by "`by'"
    if "`benchmark_by'" == "" & "`industry'" != "" {
        local benchmark_by "`industry'"
    }
    local use_bygroup = ("`benchmark_by'" != "")

    // cohort() is metadata-only on the current public path, but the exact
    // variable token is still part of the public parser contract. Enforce it
    // before the grouped unsupported-option gate so grouped runs cannot hide
    // explicit cohort() abbreviations behind a generic grouped-path error.
    if `"`_pte_cohort_literal'"' != "" {
        local _pte_cohort_resolved = lower(strtrim(`"`cohort'"'))
        if `"`_pte_cohort_literal'"' != `"`_pte_cohort_resolved'"' {
            _pte_error, errcode(111) ///
                msg("variable `_pte_cohort_literal' not found") ///
                suggestion("Specify the exact cohort() variable name")
        }
    }
    // cohort() stays metadata-only on the public baseline/noatt path, so its
    // numeric-input contract must not mask the grouped unsupported-option
    // gate. Validate type only after grouped routing is resolved.
    if !`use_bygroup' & "`cohort'" != "" {
        capture confirm numeric variable `cohort'
        if _rc != 0 {
            di as error "string variables not allowed in option cohort();"
            di as error "`cohort' is a string variable"
            exit 109
        }
    }

    // Use translog unless the caller explicitly requests Cobb-Douglas.
    if "`pfunc'" == "" {
        local pfunc "translog"
    }
    if "`pfunc'" != "cd" & "`pfunc'" != "translog" {
        _pte_error, errcode(198) ///
            msg("pfunc() must be 'cd' or 'translog'") ///
            suggestion("Specify pfunc(cd) or pfunc(translog)")
    }

    // User-facing display label.
    if "`pfunc'" == "cd" {
        local PFtype "Cobb-Douglas"
    }
    else {
        local PFtype "translog"
    }

    // The evolution law is implemented only up to quartic order.
    if `omegapoly' < 1 | `omegapoly' > 4 {
        _pte_error, errcode(198) ///
            msg("omegapoly() must be between 1 and 4") ///
            suggestion("Use an integer order between 1 and 4")
    }

    // The public interface defines event time on the support 0..L and passes
    // only the realized upper bound to the ATT worker.
    if `attperiods' < 0 {
        _pte_error, errcode(198) ///
            msg("attperiods() must be non-negative") ///
            suggestion("Use a single integer upper bound, e.g. attperiods(4)")
    }
    if `eps0window' < 0 {
        _pte_error, errcode(198) ///
            msg("eps0window() must be non-negative") ///
            suggestion("Use eps0window(0) for all untreated pre-treatment support, or a positive integer window")
    }

    // Preserve the caller's raw nsim() request so benchmark presets can
    // distinguish an explicit auto sentinel from an explicit numeric count.
    local _pte_nsim_requested = `nsim'

    // -1 is an internal sentinel for the automatic simulation-path rule.
    if `nsim' == -1 {
        if `omegapoly' >= 2 {
            local nsim = 100
        }
        else {
            local nsim = 1
        }
    }
    if `nsim' < 1 {
        _pte_error, errcode(198) ///
            msg("nsim() must be >= 1") ///
            suggestion("Use nsim(100) for Monte Carlo simulation, or nsim(-1) for automatic")
    }

    local _pte_user_omegapoly = `omegapoly'
    local _pte_user_attperiods = `attperiods'
    local _pte_user_nsim = `nsim'
    local _pte_user_eps0window = `eps0window'

    // Bootstrap inference reruns the full estimator, so reject combinations
    // that are undefined or would silently skip ATT computation.
    if `bootstrap' < 0 {
        _pte_error, errcode(198) ///
            msg("bootstrap() must be non-negative")
    }
    if `bootstrap' == 1 {
        _pte_error, errcode(198) ///
            msg("bootstrap() must be 0 (no bootstrap) or >= 2") ///
            suggestion("Use bootstrap(0) to skip or bootstrap(200) for inference")
    }
    if `bootstrap' > 0 & `bootstrap' < 50 {
        _pte_error, errcode(198) ///
            msg("bootstrap() must be 0 (no bootstrap) or at least 50 for inference") ///
            suggestion("Use bootstrap(50) or more; bootstrap(200) is recommended for reported results")
    }
    if "`saving'" != "" & `bootstrap' == 0 {
        _pte_error, errcode(198) ///
            msg("saving() requires bootstrap() >= 2") ///
            suggestion("Remove saving() for point estimation, or specify bootstrap(200) (or another value >= 2)")
    }
    if "`noparallel'" != "" & (`bootstrap' == 0 | !`use_bygroup') {
        _pte_error, errcode(198) ///
            msg("noparallel requires by()/industry() with bootstrap() >= 2") ///
            suggestion("Use noparallel only on the grouped bootstrap path, or remove it from point-estimation and non-grouped runs")
    }
    if `_pte_has_processors' & (`bootstrap' == 0 | !`use_bygroup') {
        _pte_error, errcode(198) ///
            msg("processors() requires by()/industry() with bootstrap() >= 2") ///
            suggestion("Use processors() only on the grouped bootstrap path, or remove it from point-estimation and non-grouped runs")
    }
    if `_pte_has_processors' & `processors' <= 0 {
        _pte_error, errcode(198) ///
            msg("processors() must be a positive integer when specified") ///
            suggestion("Use processors(2) or another positive worker count, or omit processors() for automatic grouped parallel selection")
    }
    if "`noatt'" != "" & `bootstrap' > 0 {
        _pte_error, errcode(198) ///
            msg("noatt cannot be combined with bootstrap(`bootstrap')") ///
            suggestion("Use noatt with bootstrap(0) for production-function-only estimation, or remove noatt to estimate ATT with bootstrap inference")
    }
    if "`noatt'" != "" & `_pte_has_seed' {
        _pte_error, errcode(198) ///
            msg("seed() cannot be combined with noatt") ///
            suggestion("Remove seed() on production-function/omega-only runs, or remove noatt to execute ATT/bootstrap RNG stages")
    }
    if `lagperiods' < 0 {
        _pte_error, errcode(198) ///
            msg("lagperiods() must be non-negative") ///
            suggestion("Use lagperiods(0) on the current public path, or remove lagperiods()")
    }
    if `persistperiods' < 0 {
        _pte_error, errcode(198) ///
            msg("persistperiods() must be non-negative") ///
            suggestion("Use persistperiods(0) to disable the filter, or a positive integer with nonabsorbing")
    }
    if "`switchdirection'" != "" {
        local switchdirection = lower(strtrim("`switchdirection'"))
    }
    if "`normalize'" != "" {
        local normalize = lower(strtrim("`normalize'"))
    }

    // Grouped public routes expose only the grouped baseline / grouped-noatt
    // contract. Reject all grouped extension flags before baseline-specific
    // validators can suggest unavailable grouped branches.
    if `use_bygroup' & ("`counterfactual'" != "" | "`nonabsorbing'" != "" ///
        | "`treatdependent'" != "" | `lagperiods' > 0 | "`targetgroup'" != "" ///
        | "`switchdirection'" != "" | `persistperiods' > 0 | "`cohort'" != "" ///
        | "`normalize'" != "" | "`attnorm'" != "") {
        _pte_error, errcode(198) ///
            msg("by()/industry() is currently available only for the grouped baseline path (with ATT) or grouped noatt") ///
            suggestion("Remove grouped extension options and re-run the baseline grouped path, or use noatt for grouped production/evolution-only estimation")
    }
    if `lagperiods' > 0 {
        _pte_error, errcode(198) ///
            msg("lagperiods() is not implemented in the current pte main-command estimation path") ///
            suggestion("Remove lagperiods() and use the baseline estimator path")
    }
    if `persistperiods' > 0 & "`nonabsorbing'" == "" {
        _pte_error, errcode(198) ///
            msg("persistperiods() requires nonabsorbing") ///
            suggestion("Use persistperiods() only with nonabsorbing, or remove it from the baseline absorbing-treatment path")
    }
    if "`switchdirection'" != "" {
        if "`nonabsorbing'" == "" {
            _pte_error, errcode(198) ///
                msg("switchdirection() requires nonabsorbing") ///
                suggestion("Use switchdirection() only with nonabsorbing, or remove it from the baseline absorbing-treatment path")
        }
        if !inlist("`switchdirection'", "both", "on", "off") {
            _pte_error, errcode(3002) ///
                msg("switchdirection() must be 'both', 'on', or 'off'") ///
                suggestion("See help pte for valid switchdirection() values")
        }
    }
    if "`normalize'" != "" {
        if !inlist("`normalize'", "none", "indexing", "benchmark") {
            _pte_error, errcode(198) ///
                msg("normalize() must be one of: none, indexing, benchmark") ///
                suggestion("Use normalize(indexing), normalize(benchmark), or normalize(none)")
        }
    }
    if "`normalize'" != "" & "`treatdependent'" == "" {
        _pte_error, errcode(198) ///
            msg("normalize() requires treatdependent") ///
            suggestion("Add treatdependent, or remove normalize() from the baseline production-function path")
    }
    if "`attnorm'" != "" & "`noatt'" != "" {
        _pte_error, errcode(198) ///
            msg("attnorm cannot be combined with noatt") ///
            suggestion("Remove noatt to compute normalized ATT objects, or remove attnorm to run production-function/omega-only estimation")
    }
    if "`attnorm'" != "" {
        if "`treatdependent'" == "" | "`normalize'" != "indexing" {
            _pte_error, errcode(198) ///
                msg("attnorm requires treatdependent normalize(indexing)") ///
                suggestion("Use attnorm only together with treatdependent normalize(indexing)")
        }
    }

    // Keep confidence levels inside Stata's supported display range.
    if `level' < 10 | `level' > 99 {
        _pte_error, errcode(198) ///
            msg("level() must be between 10 and 99")
    }

    // Public pte does not expose the Appendix D counterfactual timing
    // contract. Reject unsupported counterfactual flags, and bare
    // targetgroup() misuse, before dependency or xtset checks so pure
    // interface errors are not masked by unrelated data-state failures.
    if "`counterfactual'" != "" {
        _pte_error, errcode(198) ///
            msg("counterfactual is not available in the current public pte main-command workflow") ///
            suggestion("Use the dedicated counterfactual workers after preparing targetgroup(), referencetime(), and expansiontime(); the public pte command estimates the baseline ATT path only")
    }
    if "`targetgroup'" != "" {
        _pte_error, errcode(3006) ///
            msg("targetgroup() requires counterfactual") ///
            suggestion("Use targetgroup() only with counterfactual, or remove targetgroup() from the baseline ATT path")
    }

    // replicate() pins benchmark configurations, including the default seed,
    // polynomial order, simulation count, and eps0 trimming behavior.
    local is_replicate = 0
    local seed_replicate = .
    local replicate_omegapoly = .
    local replicate_attperiods = .
    local replicate_nsim = .
    local replicate_eps0window = .
    local replicate_legacy_pooled_eps0 = 0
    local _pte_has_notrimeps = ("`notrimeps'" != "")
    if "`replicate'" != "" {
        local replicate = lower(strtrim("`replicate'"))
        local is_replicate = 1

        if "`replicate'" == "order1" {
            local seed_replicate = 123456
            local replicate_omegapoly = 1
            local replicate_nsim = 1
            local notrimeps ""
        }
        else if "`replicate'" == "order2" {
            local seed_replicate = 123456
            local replicate_omegapoly = 2
            local replicate_nsim = 1
            local notrimeps ""
        }
        else if "`replicate'" == "order3" {
            local seed_replicate = 123456
            if "`pfunc'" == "translog" {
                local seed_replicate = 10000
            }
            local replicate_omegapoly = 3
            local replicate_nsim = 100
            local notrimeps ""
        }
        else if inlist("`replicate'", "pool_trlg", "pooled_translog") {
            local seed_replicate = 10000
            local replicate_omegapoly = 3
            local replicate_nsim = 100
            local replicate_attperiods = 3
            local replicate_legacy_pooled_eps0 = 1
            local notrimeps ""
            if "`pfunc'" == "cd" {
                _pte_error, errcode(198) ///
                    msg("replicate(`replicate') requires pfunc(translog), incompatible with pfunc(cd)") ///
                    suggestion("Remove pfunc(cd) or use a different replicate() mode")
            }
        }
        else if inlist("`replicate'", "table1", "table5") {
            local seed_replicate = 10000
            local replicate_omegapoly = 3
            local replicate_nsim = 100
            local replicate_eps0window = 3
            local notrimeps ""
            if "`replicate'" == "table1" {
                local replicate_attperiods = 3
            }
            // These benchmark modes are defined only for the translog path.
            if "`pfunc'" == "cd" {
                _pte_error, errcode(198) ///
                    msg("replicate(`replicate') requires pfunc(translog), incompatible with pfunc(cd)") ///
                    suggestion("Remove pfunc(cd) or use a different replicate() mode")
            }
        }
        else if "`replicate'" == "table_e4" {
            local seed_replicate = 10000
            local replicate_omegapoly = 3
            local replicate_nsim = 100
            local replicate_eps0window = 3
            local notrimeps ""
            // This benchmark mode is defined only for the translog path.
            if "`pfunc'" == "cd" {
                _pte_error, errcode(198) ///
                    msg("replicate(table_e4) requires pfunc(translog), incompatible with pfunc(cd)") ///
                    suggestion("Remove pfunc(cd) or use a different replicate() mode")
            }
        }
        else if "`replicate'" == "order4" {
            local seed_replicate = 123456
            local replicate_omegapoly = 4
            local replicate_nsim = 1
            local notrimeps ""
        }
        else {
            _pte_error, errcode(198) ///
                msg("replicate() must be one of: table1, table5, table_e4, pool_trlg, pooled_translog, order1, order2, order3, order4") ///
                suggestion("See help pte for valid replicate() modes")
        }

        // Table 1 and Table 5 are ATT benchmarks in the paper/DO chain, so
        // public noatt must fail closed instead of silently downgrading them
        // to production-function-only runs. Table E.4 is the dedicated
        // production-function benchmark, so the public ATT path must fail
        // closed instead of silently dispatching ATT/grouped consumers.
        if "`noatt'" != "" & inlist("`replicate'", "table1", "table5", "pool_trlg", "pooled_translog") {
            _pte_error, errcode(198) ///
                msg("replicate(`replicate') requires ATT estimation and cannot be combined with noatt") ///
                suggestion("Remove noatt to reproduce the ATT benchmark, or use replicate(table_e4) for the production-function benchmark")
        }
        if "`noatt'" == "" & "`replicate'" == "table_e4" {
            _pte_error, errcode(198) ///
                msg("replicate(table_e4) is a production-function benchmark and requires noatt") ///
                suggestion("Add noatt to reproduce the production-function benchmark, or use replicate(table1)/replicate(table5) for ATT benchmarks")
        }
        if `use_bygroup' & inlist("`replicate'", "table1", "table5", "pool_trlg", "pooled_translog") {
            _pte_error, errcode(198) ///
                msg("replicate(`replicate') is a pooled ATT benchmark and cannot be combined with by()/industry()") ///
                suggestion("Remove by()/industry() to reproduce the pooled paper table, or use the grouped path without replicate(`replicate')")
        }

        if (`_pte_has_omegapoly' | `_pte_has_poly') & `replicate_omegapoly' != `_pte_user_omegapoly' {
            _pte_error, errcode(198) ///
                msg("replicate(`replicate') conflicts with explicit omegapoly()/poly() = `_pte_user_omegapoly'") ///
                suggestion("Remove omegapoly()/poly(), or use the benchmark order implied by replicate(`replicate')")
        }
        if `_pte_has_nsim' & `_pte_nsim_requested' != -1 & ///
            `replicate_nsim' != `_pte_user_nsim' {
            _pte_error, errcode(198) ///
                msg("replicate(`replicate') conflicts with explicit nsim(`_pte_user_nsim')") ///
                suggestion("Remove nsim(), or use the benchmark simulation count implied by replicate(`replicate')")
        }
        if !missing(`replicate_eps0window') & `_pte_has_eps0window' & ///
            `replicate_eps0window' != `_pte_user_eps0window' {
            _pte_error, errcode(198) ///
                msg("replicate(`replicate') conflicts with explicit eps0window(`_pte_user_eps0window')") ///
                suggestion("Remove eps0window(), or use eps0window(`replicate_eps0window') to match replicate(`replicate')")
        }
        if `replicate_legacy_pooled_eps0' & `_pte_has_eps0window' {
            _pte_error, errcode(198) ///
                msg("replicate(`replicate') uses the historical pooled DO eps0 support and cannot be combined with eps0window()") ///
                suggestion("Remove eps0window() when reproducing DOs/att_estimation_pool_trlg.do")
        }
        if !missing(`replicate_attperiods') & `_pte_has_attperiods' & ///
            `replicate_attperiods' != `_pte_user_attperiods' {
            _pte_error, errcode(198) ///
                msg("replicate(`replicate') conflicts with explicit attperiods(`_pte_user_attperiods')") ///
                suggestion("Remove attperiods(), or use attperiods(`replicate_attperiods') to match replicate(`replicate')")
        }
        if `_pte_has_notrimeps' {
            _pte_error, errcode(198) ///
                msg("replicate(`replicate') conflicts with explicit notrimeps") ///
                suggestion("Remove notrimeps, or run the non-benchmark path without replicate() if you want the untrimmed eps0 specification")
        }

        local omegapoly = `replicate_omegapoly'
        local poly = `omegapoly'
        local nsim = `replicate_nsim'
        if !missing(`replicate_attperiods') {
            local attperiods = `replicate_attperiods'
        }
        if !missing(`replicate_eps0window') {
            local eps0window = `replicate_eps0window'
        }
    }

    // Pooled translog paper benchmarks use the DO's industry-specific time
    // trends in the first-stage proxy regression, but remain pooled for
    // omega, eps0, simulation, and ATT. This internal trend variable must not
    // route the public command through by()/industry().
    local _pte_benchmark_ttrendby ""
    local _pte_benchmark_ttrendvars ""
    if `is_replicate' & !`use_bygroup' & "`pfunc'" == "translog" & ///
        inlist("`replicate'", "table1", "table5", "table_e4", "pool_trlg", "pooled_translog") {
        local _pte_has_do_tvars = 1
        local _pte_do_tvars ""
        forvalues _pte_j = 1/6 {
            capture confirm variable t`_pte_j', exact
            if _rc != 0 {
                local _pte_has_do_tvars = 0
            }
            local _pte_do_tvars "`_pte_do_tvars' t`_pte_j'"
        }
        if `_pte_has_do_tvars' {
            local _pte_benchmark_ttrendvars "`_pte_do_tvars'"
        }
        else {
            capture confirm variable indid_adj, exact
            if _rc == 0 {
                local _pte_benchmark_ttrendby "indid_adj"
            }
        }
    }

    // Preserve whether the caller omitted seed() so benchmark-by paths can
    // still apply the official industry defaults after the generic serial
    // seed resolution below.
    local seed_was_omitted = !`_pte_has_seed'
    local seed_user = .
    if `_pte_has_seed' {
        local seed_user = `seed'
    }

    // -1 means seed() was omitted. Seed priority is:
    // explicit seed() > serial-bootstrap default 1 > replicate() point-path
    // default > package point-path default 123456.
    local seed_source = "default"
    if `_pte_has_seed' {
        // Preserve explicit user control metadata even inside benchmark mode.
        // The serial point path still passes the fixed ATT point seed
        // downstream, so warning about an overridden replicate() seed here
        // would be false on the public non-bootstrap path.
        local seed_source = "user"
    }
    else if `bootstrap' > 0 {
        // Official serial bootstrap DOs use set seed b, so the wrapper must
        // default the starting outer seed to 1 when seed() is omitted.
        if `replicate_legacy_pooled_eps0' {
            local seed = 10000
            local seed_source = "replicate"
        }
        else {
            local seed = 1
            local seed_source = "default"
        }
    }
    else if "`replicate'" != "" {
        // Use the benchmark point-estimation seed when seed() is absent.
        local seed = `seed_replicate'
        local seed_source = "replicate"
    }
    else {
        // Package default for the serial point-estimation path.
        local seed = 123456
        local seed_source = "default"
    }

    // Official ATT replication DO files pin the baseline bootstrap-path inner
    // simulation seed at 123456. The translog benchmark point path switches
    // to 10000 for order-3/table modes, while the serial bootstrap worker
    // applies its own order-1 benchmark exception from the DOs.
    local att_inner_seed = 123456
    local att_point_seed = 123456
    if "`pfunc'" == "translog" & "`replicate'" != "" & ///
        inlist("`replicate'", "order3", "table1", "table5", "table_e4", "pool_trlg", "pooled_translog") {
        local att_point_seed = 10000
    }
    local att_bootstrap_seed = `att_inner_seed'
    if `is_replicate' & "`pfunc'" == "translog" & `omegapoly' == 1 {
        local att_bootstrap_seed = 10000
    }
    if `replicate_legacy_pooled_eps0' {
        local att_bootstrap_seed = 10000
    }

    // Benchmark-by public paths follow the official industry defaults:
    //   - point ATT simulation: fixed 10000 (official industry DO law)
    //   - bootstrap group seed: 10000 for CD, 20000 for translog
    // Keep e(seed) as wrapper metadata, but do not let explicit seed()
    // rewrite the grouped point ATT simulation seed.
    local bygroup_point_seed = 10000
    local bygroup_boot_seed = `seed'
    if `use_bygroup' & `seed_was_omitted' {
        if `bootstrap' >= 2 & "`pfunc'" == "translog" {
            local bygroup_boot_seed = 20000
        }
        else {
            local bygroup_boot_seed = 10000
        }
        // Public grouped metadata should follow the same official default
        // seed law that drives the grouped point/bootstrap handoff rather
        // than leaking the serial wrapper omission default 123456.
        local seed = `bygroup_boot_seed'
        // Grouped paths override the serial replicate seed defaults with the
        // official industry defaults, so the public metadata must describe
        // the realized default source rather than the skipped serial branch.
        local seed_source = "default"
    }

    // Serial bootstrap consumes seed, seed+1, ..., seed+B-1, so the starting
    // value must leave enough room inside Stata's valid integer seed range.
    // The benchmark-by bootstrap path is different: it resets one grouped seed
    // per group and then consumes the live RNG stream inside the worker, so no
    // outer seed sequence bound applies there beyond Stata's own max seed.
    if `seed' <= 0 {
        _pte_error, errcode(198) ///
            msg("seed() must be a positive integer, got `seed'") ///
            suggestion("Use a positive integer, e.g., seed(123456)")
    }
    if `seed' > 2147483647 {
        _pte_error, errcode(198) ///
            msg("seed() must be less than 2147483648, got `seed'") ///
            suggestion("Use a smaller seed value")
    }
    if `bootstrap' > 0 & !`use_bygroup' {
        local max_seed_start = 2147483647 - `bootstrap' + 1
        if `seed' > `max_seed_start' {
            _pte_error, errcode(198) ///
                msg("seed() is too large for bootstrap(`bootstrap')") ///
            suggestion("Use seed() <= `max_seed_start' so the outer bootstrap seed sequence stays within Stata's valid range")
        }
    }

    local _bg_n_controls : word count `control'

    // The official treatdependent DO path uses only the internal time-trend
    // control. Allowing an explicit public control() here creates a producer /
    // consumer contract that the treatdependent e(b) and omega consumers do
    // not support faithfully.
    if "`treatdependent'" != "" & "`control'" != "" {
        _pte_error, errcode(198) ///
            msg("treatdependent does not accept explicit control() on the public pte path") ///
            suggestion("Remove control() and let the treatdependent branch use its internal time-trend control, matching the official DO workflow")
    }

    // Check only dependencies implied by the resolved option set so optional
    // branches do not block simpler estimation paths.
    local _dep_opts ""
    if "`treatdependent'" != "" {
        local _dep_opts "`_dep_opts' treatdependent"
    }
    if "`notrimeps'" != "" {
        local _dep_opts "`_dep_opts' notrimeps"
    }

    capture quietly pte_check_deps, `_dep_opts'
    local _depcheck_rc = _rc
    if `_depcheck_rc' != 0 {
        _pte_error, errcode(601) ///
            msg("Dependency check failed to run (rc = `_depcheck_rc')") ///
            suggestion("Verify that pte_check_deps.ado is on adopath and re-run pte")
    }

    local _deps_ok = r(all_satisfied)
    if missing(`_deps_ok') | `_deps_ok' != 1 {
        noisily pte_check_deps, `_dep_opts'
        _pte_error, errcode(601) ///
            msg("Required package dependencies are missing") ///
            suggestion("Install the missing packages shown above, then re-run pte")
    }

    // Public input admissibility must not depend on panel declaration. Check
    // existence, exact-name binding, and single-input arity before xtset/tsset
    // so a missing panel declaration cannot mask a typo in the estimator
    // interface documented by the help file.
    foreach v in `depvar' `free' `state' `proxy' `treatment' {
        capture confirm variable `v', exact
        if _rc != 0 {
            _pte_error, errcode(111) ///
                msg("Variable '`v'' not found") ///
                suggestion("Check variable names in option specification")
        }
    }

    local _fnum: word count `free'
    local _pnum: word count `proxy'
    local _snum: word count `state'
    if `_fnum' > 1 {
        _pte_error, errcode(198) ///
            msg("free() currently supports a single variable in the public pte command") ///
            suggestion("Use one flexible input variable, e.g. free(lnl)")
    }
    if `_snum' > 1 {
        _pte_error, errcode(198) ///
            msg("state() currently supports a single variable in the public pte command") ///
            suggestion("Use one state variable, e.g. state(lnk)")
    }
    if `_pnum' > 1 {
        _pte_error, errcode(198) ///
            msg("proxy() currently supports a single variable in the public pte command") ///
            suggestion("Use one proxy variable, e.g. proxy(lnm)")
    }

    local _pte_depvar_resolved = lower(`"`depvar'"')
    local _pte_free_resolved = lower(`"`free'"')
    local _pte_state_resolved = lower(`"`state'"')
    local _pte_proxy_resolved = lower(`"`proxy'"')
    if `"`_pte_depvar_literal'"' != "" & `"`_pte_depvar_literal'"' != `"`_pte_depvar_resolved'"' {
        _pte_error, errcode(111) ///
            msg("Variable '`_pte_depvar_literal'' not found") ///
            suggestion("Specify the exact dependent variable name")
    }
    if `_fnum' == 1 & `"`_pte_free_literal'"' != "" & `"`_pte_free_literal'"' != `"`_pte_free_resolved'"' {
        _pte_error, errcode(111) ///
            msg("Variable '`_pte_free_literal'' not found") ///
            suggestion("Specify the exact free() variable name")
    }
    if `_snum' == 1 & `"`_pte_state_literal'"' != "" & `"`_pte_state_literal'"' != `"`_pte_state_resolved'"' {
        _pte_error, errcode(111) ///
            msg("Variable '`_pte_state_literal'' not found") ///
            suggestion("Specify the exact state() variable name")
    }
    if `_pnum' == 1 & `"`_pte_proxy_literal'"' != "" & `"`_pte_proxy_literal'"' != `"`_pte_proxy_resolved'"' {
        _pte_error, errcode(111) ///
            msg("Variable '`_pte_proxy_literal'' not found") ///
            suggestion("Specify the exact proxy() variable name")
    }
    if `"`_pte_control_literal'"' != "" & "`control'" != "" {
        local _pte_control_literal = lower(itrim(strtrim(`"`_pte_control_literal'"')))
        local _pte_control_resolved = lower(itrim(strtrim(`"`control'"')))
        if `"`_pte_control_literal'"' != `"`_pte_control_resolved'"' {
            _pte_error, errcode(111) ///
                msg("control() variables must be specified with exact existing variable names") ///
                suggestion("Specify the exact control() variable names without abbreviation fallback")
        }
    }

    // Inherit panel identifiers from the live xtset when available. If
    // pte_setup has already published a complete dataset-scoped panel
    // contract and restored the caller's no-xtset state, materialize that
    // audited contract here so the setup/estimation chain stays closed.
    local _pte_entry_had_xtset 0
    local _pte_entry_panel ""
    local _pte_entry_time ""
    local _pte_entry_delta ""
    capture quietly xtset
    if _rc == 0 {
        local _pte_entry_had_xtset 1
        local _pte_entry_panel "`r(panelvar)'"
        local _pte_entry_time "`r(timevar)'"
        local _pte_entry_delta "`r(tdelta)'"
    }

    local _pte_setup_panelvar : char _dta[_pte_setup_panelvar]
    local _pte_setup_timevar : char _dta[_pte_setup_timevar]
    local _pte_setup_treatment : char _dta[_pte_setup_treatment]
    local _pte_setup_treatsig : char _dta[_pte_setup_treatsig]
    local _pte_setup_xtdelta : char _dta[_pte_setup_xtdelta]
    local _pte_has_sp = (`"`_pte_setup_panelvar'"' != "")
    local _pte_has_st = (`"`_pte_setup_timevar'"' != "")
    local _pte_has_sd = (`"`_pte_setup_treatment'"' != "")
    local _pte_has_ss = (`"`_pte_setup_treatsig'"' != "")
    local _pte_has_sx = (`"`_pte_setup_xtdelta'"' != "")
    local _pte_has_setup = ///
        (`_pte_has_sp' | `_pte_has_st' | `_pte_has_sd' | `_pte_has_ss' | `_pte_has_sx')
    local _pte_has_setup_full = ///
        (`_pte_has_sp' & `_pte_has_st' & `_pte_has_sd' & `_pte_has_ss' & `_pte_has_sx')

    if `_pte_has_setup' & !`_pte_has_setup_full' {
        quietly _pte_restore_xtset_contract, hadxtset(`_pte_entry_had_xtset') ///
            panel(`"`_pte_entry_panel'"') time(`"`_pte_entry_time'"') ///
            delta(`"`_pte_entry_delta'"')
        _pte_error, errcode(459) ///
            msg("Stored pte_setup panel contract is incomplete") ///
            suggestion("Re-run pte_setup on the current dataset, or use xtset panelvar timevar before pte")
    }
    if `_pte_has_setup_full' {
        if `"`_pte_setup_treatment'"' != `"`treatment'"' {
            quietly _pte_restore_xtset_contract, hadxtset(`_pte_entry_had_xtset') ///
                panel(`"`_pte_entry_panel'"') time(`"`_pte_entry_time'"') ///
                delta(`"`_pte_entry_delta'"')
            _pte_error, errcode(459) ///
                msg("Stored pte_setup treatment() contract does not match treatment(`treatment')") ///
                suggestion("Re-run pte_setup with treatment(`treatment'), or use the treatment variable audited by the stored setup contract")
        }
        capture confirm variable `_pte_setup_panelvar', exact
        if _rc != 0 {
            quietly _pte_restore_xtset_contract, hadxtset(`_pte_entry_had_xtset') ///
                panel(`"`_pte_entry_panel'"') time(`"`_pte_entry_time'"') ///
                delta(`"`_pte_entry_delta'"')
            _pte_error, errcode(111) ///
                msg("Stored pte_setup panel variable '`_pte_setup_panelvar'' not found") ///
                suggestion("Re-run pte_setup on the current dataset before pte")
        }
        capture confirm variable `_pte_setup_timevar', exact
        if _rc != 0 {
            quietly _pte_restore_xtset_contract, hadxtset(`_pte_entry_had_xtset') ///
                panel(`"`_pte_entry_panel'"') time(`"`_pte_entry_time'"') ///
                delta(`"`_pte_entry_delta'"')
            _pte_error, errcode(111) ///
                msg("Stored pte_setup time variable '`_pte_setup_timevar'' not found") ///
                suggestion("Re-run pte_setup on the current dataset before pte")
        }
        capture quietly _pte_treatment_signature, ///
            panelvar(`_pte_setup_panelvar') timevar(`_pte_setup_timevar') ///
            treatment(`treatment')
        if _rc != 0 | `"`r(signature)'"' == "" | ///
            `"`r(signature)'"' != `"`_pte_setup_treatsig'"' {
            quietly _pte_restore_xtset_contract, hadxtset(`_pte_entry_had_xtset') ///
                panel(`"`_pte_entry_panel'"') time(`"`_pte_entry_time'"') ///
                delta(`"`_pte_entry_delta'"')
            _pte_error, errcode(459) ///
                msg("Stored pte_setup treatment law no longer matches the current data") ///
                suggestion("Re-run pte_setup on the current dataset before pte")
        }
        if `"`_pte_setup_xtdelta'"' != "" {
            quietly xtset `_pte_setup_panelvar' `_pte_setup_timevar', ///
                delta(`_pte_setup_xtdelta')
        }
        else {
            quietly xtset `_pte_setup_panelvar' `_pte_setup_timevar'
        }
    }

    capture _xt, trequired
    if _rc != 0 {
        quietly _pte_restore_xtset_contract, hadxtset(`_pte_entry_had_xtset') ///
            panel(`"`_pte_entry_panel'"') time(`"`_pte_entry_time'"') ///
            delta(`"`_pte_entry_delta'"')
        _pte_error, errcode(459) ///
            msg("Data must be xtset as panel") ///
            suggestion("Use: xtset panelvar timevar")
    }
    local panelvar = r(ivar)
    local timevar = r(tvar)
    local xtdelta = "`r(tdelta)'"

    // Store the resolved panel keys under the names expected downstream.
    local id "`panelvar'"
    local time "`timevar'"
    local _pte_xtset_delta_opt ""
    if "`xtdelta'" != "" {
        local _pte_xtset_delta_opt ", delta(`xtdelta')"
    }

    // Validate that the variable partition is well defined before estimation.

    // Inputs, controls, and proxies must be disjoint.
    local chk1: list free & state
    local chk2: list free & control
    local chk3: list free & proxy
    local chk4: list state & control
    local chk5: list state & proxy
    local chk6: list control & proxy

    forvalues i = 1/6 {
        if "`chk`i''" != "" {
            quietly _pte_restore_xtset_contract, hadxtset(`_pte_entry_had_xtset') ///
                panel(`"`_pte_entry_panel'"') time(`"`_pte_entry_time'"') ///
                delta(`"`_pte_entry_delta'"')
            _pte_error, errcode(198) ///
                msg("Same variables in free, state, control or proxy: `chk`i''") ///
                suggestion("Each variable should appear in only one option")
        }
    }

    // treatment() must stay separate from the production-function variables.
    local _treat_list "`treatment'"
    local chk_t1: list _treat_list & free
    local chk_t2: list _treat_list & state
    local chk_t3: list _treat_list & proxy
    local chk_t4: list _treat_list & control

    foreach chk in chk_t1 chk_t2 chk_t3 chk_t4 {
        if "``chk''" != "" {
            quietly _pte_restore_xtset_contract, hadxtset(`_pte_entry_had_xtset') ///
                panel(`"`_pte_entry_panel'"') time(`"`_pte_entry_time'"') ///
                delta(`"`_pte_entry_delta'"')
            _pte_error, errcode(198) ///
                msg("Treatment variable cannot overlap with other variables") ///
                suggestion("Remove treatment variable from free/state/proxy/control")
        }
    }

    // The current public path delegates to single-input workers for the
    // flexible input, state input, and proxy variable. Reject wider varlists
    // here instead of letting deeper syntax mismatches surface as generic
    // estimation failures.
    // Build the baseline estimation sample from [if] [in] plus the variables
    // that every public-path estimator stage requires downstream.
    tempvar _pte_touse
    marksample _pte_touse
    markout `_pte_touse' `depvar' `free' `state' `proxy' `treatment' `id' `time'
    if "`control'" != "" {
        markout `_pte_touse' `control'
    }
    if "`benchmark_by'" != "" {
        capture confirm numeric variable `benchmark_by'
        if _rc == 0 {
            markout `_pte_touse' `benchmark_by'
        }
        else {
            // Grouped public paths accept string grouping keys. Keep the
            // sample contract aligned with _pte_bygroup by filtering only
            // truly missing/blank group labels instead of sending strings
            // through numeric markout().
            quietly replace `_pte_touse' = 0 if `_pte_touse' & missing(`benchmark_by')
        }
    }
    if "`_pte_benchmark_ttrendby'" != "" {
        markout `_pte_touse' `_pte_benchmark_ttrendby'
    }
    if "`_pte_benchmark_ttrendvars'" != "" {
        markout `_pte_touse' `_pte_benchmark_ttrendvars'
    }
    // cohort() is currently a reserved/design-check option in the public
    // main-command path, so missing cohort metadata must not change the
    // baseline estimation sample.
    quietly count if `_pte_touse'
    if r(N) == 0 {
        quietly _pte_restore_xtset_contract, hadxtset(`_pte_entry_had_xtset') ///
            panel(`"`_pte_entry_panel'"') time(`"`_pte_entry_time'"') ///
            delta(`"`_pte_entry_delta'"')
        _pte_error, errcode(2000) ///
            msg("No observations remain after applying if/in and required-variable filters") ///
            suggestion("Relax if/in conditions or check missing values in the model variables")
    }

    // The public estimator is defined only for a binary treatment indicator
    // on the active estimation sample. Reject invalid coding before any
    // support or Assumption 3.3 checks can misclassify the failure.
    quietly count if `_pte_touse' & !inlist(`treatment', 0, 1) & !missing(`treatment')
    if r(N) > 0 {
        quietly _pte_restore_xtset_contract, hadxtset(`_pte_entry_had_xtset') ///
            panel(`"`_pte_entry_panel'"') time(`"`_pte_entry_time'"') ///
            delta(`"`_pte_entry_delta'"')
        _pte_error, errcode(198) ///
            msg("treatment() must be coded 0/1 in the estimation sample") ///
            suggestion("Recode treatment() so untreated observations are 0 and treated observations are 1")
    }

    // Reject extension-option contract violations before any sample-support
    // diagnostics so invalid public option combinations do not get masked by
    // downstream treatment-variation or Assumption 3.3 errors.
    local _pcc_opts "treatment(`treatment') `nonabsorbing' `treatdependent'"
    local _pcc_opts "`_pcc_opts' lagperiods(`lagperiods') `counterfactual'"
    local _pcc_opts "`_pcc_opts' persistperiods(`persistperiods')"
    local _pcc_opts "`_pcc_opts' touse(`_pte_touse')"
    if "`noatt'" != "" {
        local _pcc_opts "`_pcc_opts' noatt"
    }
    if "`switchdirection'" != "" {
        local _pcc_opts "`_pcc_opts' switchdirection(`switchdirection')"
    }
    // cohort() is currently a reserved/design-check option in the public
    // main-command path; do not gate baseline estimation on the internal
    // multi-cohort validator here.
    if "`targetgroup'" != "" {
        local _pcc_opts "`_pcc_opts' targetgroup(`targetgroup')"
    }
    if "`verbose'" != "" {
        local _pcc_opts "`_pcc_opts' detail"
    }
    capture noisily _pte_check_param_conflicts, `_pcc_opts'
    local _pcc_rc = _rc
    if `_pcc_rc' != 0 {
        quietly _pte_restore_xtset_contract, hadxtset(`_pte_entry_had_xtset') ///
            panel(`"`_pte_entry_panel'"') time(`"`_pte_entry_time'"') ///
            delta(`"`_pte_entry_delta'"')
        exit `_pcc_rc'
    }

    // Panel summary statistics are reported in e() and reused in displays.
    tempvar _pte_tag
    quietly egen `_pte_tag' = tag(`id') if `_pte_touse'
    quietly count if `_pte_tag' == 1
    local nGroups = r(N)

    // Panel-length summary statistics.
    tempvar _pte_Ti
    quietly bysort `id': egen double `_pte_Ti' = total(`_pte_touse')
    quietly summarize `_pte_Ti' if `_pte_tag' == 1, meanonly
    local minGroup = r(min)
    local meanGroup = r(mean)
    local maxGroup = r(max)

    // Firm-type and transition counts.
    tempvar _pte_ever_treat _pte_mid_temp _pte_L_active
    quietly bysort `id': egen byte `_pte_ever_treat' = max(cond(`_pte_touse', `treatment', 0))
    quietly count if `_pte_tag' == 1 & `_pte_ever_treat' == 1
    local N_treated = r(N)
    quietly count if `_pte_tag' == 1 & `_pte_ever_treat' == 0
    local N_control = r(N)

    // Transition observations are the periods excluded by the CLK correction.
    quietly gen byte `_pte_L_active' = (L.`_pte_touse' == 1)
    quietly gen byte `_pte_mid_temp' = (`treatment' != L.`treatment') if ///
        `_pte_touse' & `_pte_L_active' & L.`treatment' != .
    quietly count if `_pte_mid_temp' == 1
    local N_trans = r(N)

    // The estimator needs both stable untreated and stable treated spells
    // because transition observations are excluded from the GMM stage.

    // Reject degenerate treatment paths up front.
    quietly summarize `treatment' if `_pte_touse', meanonly
    if r(min) == r(max) {
        if r(min) == 0 {
            quietly _pte_restore_xtset_contract, hadxtset(`_pte_entry_had_xtset') ///
                panel(`"`_pte_entry_panel'"') time(`"`_pte_entry_time'"') ///
                delta(`"`_pte_entry_delta'"')
            _pte_error, errcode(2003) ///
                msg("No treatment variation: all observations have D=0") ///
                suggestion("Treatment variable must have both 0 and 1 values")
        }
        else {
            quietly _pte_restore_xtset_contract, hadxtset(`_pte_entry_had_xtset') ///
                panel(`"`_pte_entry_panel'"') time(`"`_pte_entry_time'"') ///
                delta(`"`_pte_entry_delta'"')
            _pte_error, errcode(2004) ///
                msg("No control group: all observations have D=1") ///
                suggestion("Treatment variable must have both 0 and 1 values")
        }
    }

    // Stable untreated observations identify the untreated evolution law.
    tempvar _pte_L_D
    quietly gen `_pte_L_D' = L.`treatment' if `_pte_touse' & `_pte_L_active'
    quietly count if `_pte_touse' & `treatment' == 0 & `_pte_L_D' == 0 & !missing(`_pte_L_D')
    local n_untreated_stable = r(N)

    if `n_untreated_stable' == 0 {
        quietly _pte_restore_xtset_contract, hadxtset(`_pte_entry_had_xtset') ///
            panel(`"`_pte_entry_panel'"') time(`"`_pte_entry_time'"') ///
            delta(`"`_pte_entry_delta'"')
        _pte_error, errcode(2001) ///
            msg("Assumption 3.3 violated: no consecutive untreated observations (D=0, L.D=0)") ///
            suggestion("Ensure data contains firms with D=0 in at least two consecutive periods")
    }

    // noatt skips ATT/Proposition 4.3 only. Production function estimation
    // still follows Theorem 3.1, whose identification requires both stable
    // untreated and stable treated support.
    local do_att = ("`noatt'" == "")

    // Stable treated observations are needed for the treated-state support.
    quietly count if `_pte_touse' & `treatment' == 1 & `_pte_L_D' == 1 & !missing(`_pte_L_D')
    local n_treated_stable = r(N)

    if `n_treated_stable' == 0 {
        quietly _pte_restore_xtset_contract, hadxtset(`_pte_entry_had_xtset') ///
            panel(`"`_pte_entry_panel'"') time(`"`_pte_entry_time'"') ///
            delta(`"`_pte_entry_delta'"')
        _pte_error, errcode(2002) ///
            msg("Assumption 3.3 violated: no consecutive treated observations (D=1, L.D=1)") ///
            suggestion("Ensure data contains firms with D=1 in at least two consecutive periods")
    }

    // A high transition share can leave too little support after CLK trimming.
    quietly count if `_pte_touse' & `treatment' != `_pte_L_D' & !missing(`_pte_L_D')
    local n_trans_check = r(N)
    quietly count if `_pte_touse' & !missing(`_pte_L_D')
    local n_total_check = r(N)

    if `n_total_check' > 0 {
        local trans_ratio = `n_trans_check' / `n_total_check'
        if `trans_ratio' > 0.5 {
            _pte_warn "High transition ratio (`n_trans_check' of `n_total_check', `=round(`trans_ratio'*100, 0.1)'%). CLK correction excludes transition observations."
        }
    }

    // nonabsorbing triggers a design check. If the realized treatment path is
    // actually absorbing, the command degrades to the standard pipeline.
    local _pte_is_degraded = 0
    local _pte_na_N_entry = 0

    if "`nonabsorbing'" != "" {
        // Count entry and exit events from the observed treatment path.
        capture noisily _pte_detect_treatment_type `treatment', id(`id') time(`time') ///
            touse(`_pte_touse') nowarn
        local _pte_detect_rc = _rc
        if `_pte_detect_rc' != 0 {
            quietly _pte_restore_xtset_contract, hadxtset(`_pte_entry_had_xtset') ///
                panel(`"`_pte_entry_panel'"') time(`"`_pte_entry_time'"') ///
                delta(`"`_pte_entry_delta'"')
            exit `_pte_detect_rc'
        }
        local _pte_na_N_exit = r(N_exit)
        local _pte_na_N_entry = r(N_entry)

        // Require enough switching support before continuing.
        capture noisily _pte_check_boundary_conditions, ///
            nentry(`_pte_na_N_entry') nexit(`_pte_na_N_exit') ///
            panelvar(`id') touse(`_pte_touse')
        local _pte_boundary_rc = _rc
        if `_pte_boundary_rc' != 0 {
            quietly _pte_restore_xtset_contract, hadxtset(`_pte_entry_had_xtset') ///
                panel(`"`_pte_entry_panel'"') time(`"`_pte_entry_time'"') ///
                delta(`"`_pte_entry_delta'"')
            exit `_pte_boundary_rc'
        }

        // Decide whether the request collapses to the absorbing case.
        capture noisily _pte_check_degradation, nexit(`_pte_na_N_exit') nentry(`_pte_na_N_entry')
        local _pte_degradation_rc = _rc
        if `_pte_degradation_rc' != 0 {
            quietly _pte_restore_xtset_contract, hadxtset(`_pte_entry_had_xtset') ///
                panel(`"`_pte_entry_panel'"') time(`"`_pte_entry_time'"') ///
                delta(`"`_pte_entry_delta'"')
            exit `_pte_degradation_rc'
        }
        local _pte_is_degraded = r(absorbing)

        if `_pte_is_degraded' == 1 {
            if `persistperiods' > 0 {
                quietly _pte_restore_xtset_contract, hadxtset(`_pte_entry_had_xtset') ///
                    panel(`"`_pte_entry_panel'"') time(`"`_pte_entry_time'"') ///
                    delta(`"`_pte_entry_delta'"')
                _pte_error, errcode(198) ///
                    msg("persistperiods() is incompatible with nonabsorbing degradation to the absorbing public path") ///
                    suggestion("Use persistperiods(0), or run the dedicated nonabsorbing helpers on data with both entry and exit events")
            }
            // Continue with the baseline absorbing-treatment pipeline.
            _pte_display_degradation_info, nentry(`_pte_na_N_entry')
        }
        else {
            // The dedicated non-absorbing estimation path is not public yet.
            di as error "Non-absorbing estimation flow not yet implemented"
            di as error "Use the absorbing-treatment workflow for now"
            quietly _pte_restore_xtset_contract, hadxtset(`_pte_entry_had_xtset') ///
                panel(`"`_pte_entry_panel'"') time(`"`_pte_entry_time'"') ///
                delta(`"`_pte_entry_delta'"')
            exit 199
        }
    }

    // attperiods() bounds are relevant only when ATT is estimated.
    if `do_att' {
        // attperiods() cannot exceed the realized post-treatment support.
        // Compute max relative time for treated firms from treatment history.
        // Do not rely on a pre-existing treat_yr0 variable, which may be absent
        // or may reflect stale session state rather than the current treatment path.
        // The event-time anchor must use the full observed treatment path, not
        // the touse()-contracted sample, to stay aligned with _pte_att.
        tempvar _treat_start_temp _treat_entry_temp _nt_temp _max_nt
        local _pte_attperiods_delta = real("`xtdelta'")
        if missing(`_pte_attperiods_delta') | `_pte_attperiods_delta' <= 0 {
            local _pte_attperiods_delta = 1
        }
        // Event-time support must be anchored to an observed 0->1 entry on the
        // full treatment path. A firm already treated at its first observed
        // period is left-censored and cannot contribute public attperiods()
        // support, because the sample does not reveal its entry e_i.
        quietly bysort `id' (`time'): gen byte `_treat_entry_temp' = ///
            (L.`treatment' == 0 & `treatment' == 1) if _n > 1
        quietly bysort `id': egen double `_treat_start_temp' = ///
            min(cond(`_treat_entry_temp' == 1, `time', .))
        quietly gen double `_nt_temp' = ///
            (`time' - `_treat_start_temp') / `_pte_attperiods_delta' if ///
            `_pte_touse' & `_pte_ever_treat' == 1
        quietly replace `_nt_temp' = round(`_nt_temp') if ///
            !missing(`_nt_temp') & abs(`_nt_temp' - round(`_nt_temp')) <= 1e-10

        quietly count if `_pte_touse' & `_pte_ever_treat' == 1 & !missing(`_nt_temp')
        if r(N) == 0 {
            quietly _pte_restore_xtset_contract, hadxtset(`_pte_entry_had_xtset') ///
                panel(`"`_pte_entry_panel'"') time(`"`_pte_entry_time'"') ///
                delta(`"`_pte_entry_delta'"')
            _pte_error, errcode(498) ///
                msg("Cannot determine relative treatment timing for treated firms") ///
                suggestion("Verify treatment() switches from 0 to 1 within the xtset panel")
        }

        quietly summarize `_nt_temp' if `_pte_touse' & `_pte_ever_treat' == 1 & !missing(`_nt_temp'), meanonly
        local max_nt = r(max)
        if `attperiods' > `max_nt' {
            quietly _pte_restore_xtset_contract, hadxtset(`_pte_entry_had_xtset') ///
                panel(`"`_pte_entry_panel'"') time(`"`_pte_entry_time'"') ///
                delta(`"`_pte_entry_delta'"')
            _pte_error, errcode(498) ///
                msg("attperiods(`attperiods') exceeds max relative time in data (`max_nt')") ///
                suggestion("Use attperiods(`max_nt') or fewer")
        }
    }

    local do_bootstrap = (`bootstrap' >= 2)
    local do_trim = ("`notrimeps'" == "")

    // Route benchmark-by estimation through the dedicated by-group workers so
    // production-function estimation, shock pools, and bootstrap remain
    // group-specific instead of pooling unrelated industries.
    if `use_bygroup' {
        local _proxy_words : word count `proxy'
        if `_proxy_words' != 1 {
            quietly _pte_restore_xtset_contract, hadxtset(`_pte_entry_had_xtset') ///
                panel(`"`_pte_entry_panel'"') time(`"`_pte_entry_time'"') ///
                delta(`"`_pte_entry_delta'"')
            _pte_error, errcode(198) ///
                msg("by()/industry() currently requires a single proxy variable") ///
                suggestion("Specify one proxy variable when running the by-group benchmark path")
        }

        if "`verbose'" != "" {
            capture noisily _pte_mata_init, verbose
        }
        else {
            capture noisily _pte_mata_init, nolog
        }
        if _rc != 0 {
            quietly _pte_restore_xtset_contract, hadxtset(`_pte_entry_had_xtset') ///
                panel(`"`_pte_entry_panel'"') time(`"`_pte_entry_time'"') ///
                delta(`"`_pte_entry_delta'"')
            _pte_error, errcode(601) ///
                msg("Mata function initialization failed") ///
                suggestion("Try: _pte_mata_init, force verbose")
        }

        if `do_bootstrap' {
            // Bootstrap bygroup still needs the point-estimate latent objects
            // in memory so public postestimation can map back to the panel.
            local _bg_point_opts "by(`benchmark_by') treatment(`treatment')"
            local _bg_point_opts "`_bg_point_opts' free(`free') state(`state') proxy(`proxy')"
            local _bg_point_opts "`_bg_point_opts' pfunc(`pfunc') poly(`poly')"
            local _bg_point_opts "`_bg_point_opts' omegapoly(`omegapoly') attperiods(`attperiods')"
            local _bg_point_opts "`_bg_point_opts' nsim(`nsim') seed(`bygroup_point_seed') bootstrap(0)"
            local _bg_point_opts "`_bg_point_opts' eps0window(`eps0window') nolog"
            if "`control'" != "" {
                local _bg_point_opts "`_bg_point_opts' control(`control')"
            }
            if "`nodiagnose'" != "" {
                local _bg_point_opts "`_bg_point_opts' nodiagnose"
            }
            if "`notrimeps'" != "" {
                local _bg_point_opts "`_bg_point_opts' notrimeps"
            }
            if "`replicate'" != "" {
                local _bg_point_opts "`_bg_point_opts' replicate"
            }

            capture noisily _pte_bygroup `depvar' if `_pte_touse', `_bg_point_opts'
            local _bg_point_rc = _rc
            if `_bg_point_rc' != 0 {
                if `_pte_has_prev_est' {
                    capture estimates restore `_pte_prev_est'
                    capture estimates drop `_pte_prev_est'
                    local _pte_has_prev_est = 0
                }
                else {
                    capture ereturn clear
                }
                quietly _pte_restore_xtset_contract, hadxtset(`_pte_entry_had_xtset') ///
                    panel(`"`_pte_entry_panel'"') time(`"`_pte_entry_time'"') ///
                    delta(`"`_pte_entry_delta'"')
                _pte_error, errcode(`_bg_point_rc') ///
                    msg("By-group point estimation failed before bootstrap handoff (rc = `_bg_point_rc')") ///
                    suggestion("Check the group variable and benchmark-path inputs")
            }

            // Preserve the point-estimate grouped matrices before the
            // bootstrap worker overwrites e(). Public postestimation still
            // needs the heterogeneous by-group point contract after
            // bootstrap inference is attached.
            tempname _bg_point_att_by _bg_point_rho_by _bg_point_sigma_by
            tempname _bg_point_n_by _bg_point_n_firms_by
            tempname _bg_point_att_n _bg_point_n_by_period
            local _bg_has_point_rho_by = 0
            local _bg_has_point_sigma_by = 0
            local _bg_has_point_n_by = 0
            local _bg_has_point_n_firms_by = 0
            local _bg_has_point_att_n = 0
            local _bg_point_att_total = .
            capture matrix `_bg_point_att_by' = e(att_by)
            capture matrix `_bg_point_rho_by' = e(rho_by)
            if _rc == 0 {
                local _bg_has_point_rho_by = 1
            }
            capture matrix `_bg_point_sigma_by' = e(sigma_by)
            if _rc == 0 {
                local _bg_has_point_sigma_by = 1
            }
            capture matrix `_bg_point_n_by' = e(N_by)
            if _rc == 0 {
                local _bg_has_point_n_by = 1
            }
            capture matrix `_bg_point_n_firms_by' = e(N_firms_by)
            if _rc == 0 {
                local _bg_has_point_n_firms_by = 1
            }
            capture matrix `_bg_point_att_n' = e(att_N)
            if _rc == 0 {
                local _bg_has_point_att_n = 1
                if colsof(`_bg_point_att_n') >= `attperiods' + 1 {
                    mata: st_matrix("`_bg_point_n_by_period'", ///
                        st_matrix("`_bg_point_att_n'")[1, 1..`=`attperiods' + 1'])
                }
                if colsof(`_bg_point_att_n') >= `attperiods' + 2 {
                    local _bg_point_att_total = ///
                        el(`_bg_point_att_n', 1, `attperiods' + 2)
                }
            }

            local _bg_boot_opts "by(`benchmark_by') treatment(`treatment')"
            local _bg_boot_opts "`_bg_boot_opts' free(`free') state(`state') proxy(`proxy')"
            local _bg_boot_opts "`_bg_boot_opts' pfunc(`pfunc') poly(`poly')"
            local _bg_boot_opts "`_bg_boot_opts' omegapoly(`omegapoly') attperiods(`attperiods')"
            local _bg_boot_opts "`_bg_boot_opts' nsim(`nsim') bootstrap(`bootstrap')"
            local _bg_boot_opts "`_bg_boot_opts' eps0window(`eps0window')"
            local _bg_boot_opts "`_bg_boot_opts' seed(`bygroup_boot_seed') level(`level')"
            if "`control'" != "" {
                local _bg_boot_opts "`_bg_boot_opts' control(`control')"
            }
            if "`nodiagnose'" != "" {
                local _bg_boot_opts "`_bg_boot_opts' nodiagnose"
            }
            if "`notrimeps'" != "" {
                local _bg_boot_opts "`_bg_boot_opts' notrimeps"
            }
            if "`saving'" != "" {
                local _bg_boot_opts "`_bg_boot_opts' saving(`saving')"
            }
            if "`noparallel'" != "" {
                local _bg_boot_opts "`_bg_boot_opts' noparallel"
            }
            if `processors' > 0 {
                local _bg_boot_opts "`_bg_boot_opts' processors(`processors')"
            }
            if "`nolog'" != "" {
                local _bg_boot_opts "`_bg_boot_opts' nolog"
            }
            if "`replicate'" != "" {
                // Grouped benchmark bootstrap follows the official industry
                // DO law: set the group seed once, then consume the live RNG
                // stream inside ATT without per-draw inner resets.
                if "`pfunc'" == "translog" {
                    local _bg_boot_opts "`_bg_boot_opts' replicate(trlg)"
                }
                else {
                    local _bg_boot_opts "`_bg_boot_opts' replicate(cd)"
                }
                // The translog order-1 industry bootstrap DO resets the
                // inner ATT/shock seed to 10000 inside each bootstrap draw.
                // Mirror that benchmark exception explicitly; keep the live
                // grouped RNG stream contract for all other grouped modes.
                if "`pfunc'" == "translog" & "`replicate'" == "order1" {
                    local _bg_boot_opts "`_bg_boot_opts' inner_seed(`att_bootstrap_seed')"
                }
            }

            capture noisily _pte_bootstrap_bygroup `depvar' if `_pte_touse', `_bg_boot_opts'
            local _bg_rc = _rc
            if `_bg_rc' != 0 {
                if `_pte_has_prev_est' {
                    capture estimates restore `_pte_prev_est'
                    capture estimates drop `_pte_prev_est'
                    local _pte_has_prev_est = 0
                }
                else {
                    capture ereturn clear
                }
                quietly _pte_restore_xtset_contract, hadxtset(`_pte_entry_had_xtset') ///
                    panel(`"`_pte_entry_panel'"') time(`"`_pte_entry_time'"') ///
                    delta(`"`_pte_entry_delta'"')
                _pte_error, errcode(`_bg_rc') ///
                    msg("By-group bootstrap estimation failed (rc = `_bg_rc')") ///
                    suggestion("Check the group variable and benchmark-path inputs")
            }
        }
        else {
            local _bg_opts "by(`benchmark_by') treatment(`treatment')"
            local _bg_opts "`_bg_opts' free(`free') state(`state') proxy(`proxy')"
            local _bg_opts "`_bg_opts' pfunc(`pfunc') poly(`poly')"
            local _bg_opts "`_bg_opts' omegapoly(`omegapoly') attperiods(`attperiods')"
            local _bg_opts "`_bg_opts' nsim(`nsim') seed(`bygroup_point_seed') bootstrap(0)"
            local _bg_opts "`_bg_opts' eps0window(`eps0window')"
            if "`control'" != "" {
                local _bg_opts "`_bg_opts' control(`control')"
            }
            if "`nodiagnose'" != "" {
                local _bg_opts "`_bg_opts' nodiagnose"
            }
            if "`notrimeps'" != "" {
                local _bg_opts "`_bg_opts' notrimeps"
            }
            if "`noatt'" != "" {
                local _bg_opts "`_bg_opts' noatt"
            }
            if "`nolog'" != "" {
                local _bg_opts "`_bg_opts' nolog"
            }
            if "`replicate'" != "" {
                local _bg_opts "`_bg_opts' replicate"
            }

            capture noisily _pte_bygroup `depvar' if `_pte_touse', `_bg_opts'
            local _bg_rc = _rc
            if `_bg_rc' != 0 {
                if `_pte_has_prev_est' {
                    capture estimates restore `_pte_prev_est'
                    capture estimates drop `_pte_prev_est'
                    local _pte_has_prev_est = 0
                }
                else {
                    capture ereturn clear
                }
                quietly _pte_restore_xtset_contract, hadxtset(`_pte_entry_had_xtset') ///
                    panel(`"`_pte_entry_panel'"') time(`"`_pte_entry_time'"') ///
                    delta(`"`_pte_entry_delta'"')
                _pte_error, errcode(`_bg_rc') ///
                    msg("By-group benchmark estimation failed (rc = `_bg_rc')") ///
                    suggestion("Check the group variable and benchmark-path inputs")
            }
        }

        // Rebuild a public eclass result. The grouped workers are eclass
        // programs, but the public pte wrapper must still publish a coherent
        // e(sample)/e(N) contract after relabeling the result as e(cmd)=pte.
        tempvar _pte_bg_esample
        quietly gen byte `_pte_bg_esample' = `_pte_touse'
        if !`do_bootstrap' {
            capture confirm variable _pte_pf_esample
            if _rc == 0 {
                quietly replace `_pte_bg_esample' = `_pte_touse' & (_pte_pf_esample == 1)
            }
            else {
                capture confirm variable _pte_mid, exact
                local _bg_has_mid = (_rc == 0)
                capture confirm variable _pte_phi
                local _bg_has_phi = (_rc == 0)
                if `_bg_has_mid' & `_bg_has_phi' {
                    tempvar _pte_bg_sort _pte_bg_has_gap _pte_bg_delta_probe
                    quietly gen long `_pte_bg_sort' = _n
                    quietly sort `id' `time'
                    quietly by `id' (`time'): gen double `_pte_bg_delta_probe' = ///
                        `time' - `time'[_n-1] if _n > 1 & !mi(`time', `time'[_n-1])
                    quietly summarize `_pte_bg_delta_probe' if `_pte_bg_delta_probe' > 0, meanonly
                    local _bg_tsdelta = r(min)
                    if missing(`_bg_tsdelta') | `_bg_tsdelta' <= 0 {
                        local _bg_tsdelta = 1
                    }
                    local _bg_tsdelta_tol = max(1e-10, abs(`_bg_tsdelta') * 1e-10)

                    quietly replace `_pte_bg_esample' = `_pte_touse' & (_pte_mid == 0)
                    quietly by `id' (`time'): gen byte `_pte_bg_has_gap' = ///
                        (abs((`time' - `time'[_n-1]) - `_bg_tsdelta') > `_bg_tsdelta_tol') if _n > 1
                    quietly by `id' (`time'): replace `_pte_bg_has_gap' = 1 if _n == 1
                    quietly replace `_pte_bg_esample' = 0 if `_pte_bg_has_gap' == 1
                    quietly replace `_pte_bg_esample' = 0 if _n > 1 & `_pte_touse'[_n-1] != 1
                    quietly replace `_pte_bg_esample' = 0 if ///
                        mi(_pte_phi) | mi(_pte_phi[_n-1]) | ///
                        mi(`depvar') | mi(`depvar'[_n-1]) | ///
                        mi(`free') | mi(`free'[_n-1]) | ///
                        mi(`state') | mi(`state'[_n-1]) | ///
                        mi(`treatment') | mi(`treatment'[_n-1])
                    quietly sort `_pte_bg_sort'
                }
                else {
                    capture confirm variable _pte_omega
                    if _rc == 0 {
                        quietly replace `_pte_bg_esample' = `_pte_touse' & !missing(_pte_omega)
                    }
                }
            }
        }
        else {
            capture confirm variable _pte_omega
            if _rc == 0 {
                quietly replace `_pte_bg_esample' = `_pte_touse' & !missing(_pte_omega)
            }
        }
        quietly count if `_pte_bg_esample'
        local pte_bg_N = r(N)

        // Preserve worker payload before ereturn post clears e(). The grouped
        // public contract is driven by rho_by / sigma_by, so grouped reposts
        // must not leak any worker-private serial rho_0/rho_1 placeholders.
        capture local _bg_groups = e(groups)
        capture local _bg_n_groups = e(n_groups)
        capture local _bg_ngroups = e(ngroups)
        capture local _bg_sigma_eps_trim = e(sigma_eps_trim)
        capture local _bg_sigma_eps = e(sigma_eps)
        local _bg_has_att_n_contract = 0
        tempname _bg_att_n_by_period

        if !`do_bootstrap' {
            tempname _bg_b_by _bg_rho_by _bg_sigma_by _bg_att_by _bg_att_pool
            tempname _bg_att_pool_trim _bg_att_pool_raw _bg_att_sd _bg_att_n _bg_n_by _bg_n_firms_by
            local _bg_has_att_pool_trim = 0
            local _bg_has_att_pool_raw = 0
            capture matrix `_bg_b_by' = e(b_by)
            capture matrix `_bg_rho_by' = e(rho_by)
            capture matrix `_bg_sigma_by' = e(sigma_by)
            if `do_att' {
                capture matrix `_bg_att_by' = e(att_by)
                capture matrix `_bg_att_pool' = e(att_pool)
                capture matrix `_bg_att_pool_trim' = e(att_pool_trim)
                if _rc == 0 {
                    if colsof(`_bg_att_pool_trim') == `attperiods' + 2 {
                        local _bg_has_att_pool_trim = 1
                    }
                }
                capture matrix `_bg_att_pool_raw' = e(att_pool_raw)
                if _rc == 0 {
                    if colsof(`_bg_att_pool_raw') == `attperiods' + 2 {
                        local _bg_has_att_pool_raw = 1
                    }
                }
                capture matrix `_bg_att_sd' = e(att_sd)
                capture matrix `_bg_att_n' = e(att_N)
                if _rc == 0 {
                    local _bg_has_att_n_contract = 1
                    if colsof(`_bg_att_n') >= `attperiods' + 1 {
                        mata: st_matrix("`_bg_att_n_by_period'", ///
                            st_matrix("`_bg_att_n'")[1, 1..`=`attperiods' + 1'])
                    }
                }
            }
            capture matrix `_bg_n_by' = e(N_by)
            capture matrix `_bg_n_firms_by' = e(N_firms_by)
        }
        else {
            tempname _bg_att_boot_all _bg_att_boot_trim
            tempname _bg_att_mean_pool _bg_att_mean_pool_trim
            tempname _bg_att_se_pool _bg_att_se_pool_trim
            tempname _bg_att_ci_lo_pool _bg_att_ci_hi_pool
            tempname _bg_att_ci_lo_trim _bg_att_ci_hi_trim
            capture matrix `_bg_att_boot_all' = e(att_boot_all)
            capture matrix `_bg_att_boot_trim' = e(att_boot_trim)
            capture matrix `_bg_att_mean_pool' = e(att_mean_pool)
            capture matrix `_bg_att_mean_pool_trim' = e(att_mean_pool_trim)
            capture matrix `_bg_att_se_pool' = e(att_se_pool)
            capture matrix `_bg_att_se_pool_trim' = e(att_se_pool_trim)
            capture matrix `_bg_att_ci_lo_pool' = e(att_ci_lower_pool)
            capture matrix `_bg_att_ci_hi_pool' = e(att_ci_upper_pool)
            capture matrix `_bg_att_ci_lo_trim' = e(att_ci_lower_trim)
            capture matrix `_bg_att_ci_hi_trim' = e(att_ci_upper_trim)
            local _bg_parallel_method ""
            capture local _bg_parallel_method `"`e(parallel_method)'"'
            if _rc != 0 | `"`_bg_parallel_method'"' == "." {
                local _bg_parallel_method ""
            }
            capture local _bg_parallel_nproc = e(parallel_nproc)
            capture local _bg_parallel_requested_nproc = e(parallel_requested_nproc)
            capture local _bg_parallel_fallback = e(parallel_fallback)
            capture local _bg_parallel_helper_rc = e(parallel_helper_rc)
            if _rc != 0 | `"`_bg_parallel_helper_rc'"' == "" | `"`_bg_parallel_helper_rc'"' == "." {
                local _bg_parallel_helper_rc ""
            }
            local _bg_parallel_requested_method ""
            capture local _bg_parallel_requested_method `"`e(parallel_requested_method)'"'
            if _rc != 0 | `"`_bg_parallel_requested_method'"' == "." {
                local _bg_parallel_requested_method ""
            }
            local _bg_parallel_fallback_reason ""
            capture local _bg_parallel_fallback_reason `"`e(parallel_fallback_reason)'"'
            if _rc != 0 | `"`_bg_parallel_fallback_reason'"' == "." {
                local _bg_parallel_fallback_reason ""
            }
            capture local _bg_nboot = e(nboot)
            capture local _bg_n_success = e(n_success)
            capture local _bg_n_fail = e(n_fail)
            capture local _bg_n_success_group = e(n_success_group)
            capture local _bg_n_fail_group = e(n_fail_group)
            capture local _bg_industry_seed = e(industry_seed)
            local _bg_inner_seed ""
            capture local _bg_inner_seed = e(inner_seed)
            if _rc != 0 | `"`_bg_inner_seed'"' == "" | `"`_bg_inner_seed'"' == "." {
                local _bg_inner_seed ""
            }
            local _bg_inner_seed_source ""
            capture local _bg_inner_seed_source `"`e(inner_seed_source)'"'
            if _rc != 0 | `"`_bg_inner_seed_source'"' == "." {
                local _bg_inner_seed_source ""
            }
            if `"`_bg_inner_seed'"' != "" & "`pfunc'" == "translog" & ///
                "`replicate'" == "order1" {
                local _bg_inner_seed_source "replicate"
            }

            local _bg_group_count = .
            if "`_bg_ngroups'" != "" & "`_bg_ngroups'" != "." {
                local _bg_group_count = `_bg_ngroups'
            }
            else if "`_bg_n_groups'" != "" & "`_bg_n_groups'" != "." {
                local _bg_group_count = `_bg_n_groups'
            }
            if !missing(`_bg_group_count') {
                local _bg_beta_colnames "beta_l beta_k beta_t"
                if "`pfunc'" != "cd" {
                    local _bg_beta_colnames "beta_l beta_k beta_l2 beta_k2 beta_lk beta_t"
                }
                if `_bg_n_controls' > 0 {
                    local _bg_beta_colnames "beta_l beta_k beta_t `control'"
                    if "`pfunc'" != "cd" {
                        local _bg_beta_colnames "beta_l beta_k beta_l2 beta_k2 beta_lk beta_t `control'"
                    }
                }
                local _bg_att_boot_names ""
                local _bg_att_trim_boot_names ""
                local _bg_att_se_names ""
                local _bg_beta_boot_names ""
                local _bg_beta_se_names ""
                forvalues _g = 1/`_bg_group_count' {
                    tempname _bg_att_boot_copy _bg_att_trim_boot_copy
                    tempname _bg_att_se_copy _bg_beta_boot_copy _bg_beta_se_copy
                    local _bg_att_boot_names "`_bg_att_boot_names' `_bg_att_boot_copy'"
                    local _bg_att_trim_boot_names "`_bg_att_trim_boot_names' `_bg_att_trim_boot_copy'"
                    local _bg_att_se_names "`_bg_att_se_names' `_bg_att_se_copy'"
                    local _bg_beta_boot_names "`_bg_beta_boot_names' `_bg_beta_boot_copy'"
                    local _bg_beta_se_names "`_bg_beta_se_names' `_bg_beta_se_copy'"
                    capture matrix `_bg_att_boot_copy' = e(att_boot_g`_g')
                    capture matrix `_bg_att_trim_boot_copy' = e(att_trim_boot_g`_g')
                    capture matrix `_bg_att_se_copy' = e(att_se_g`_g')
                    capture matrix `_bg_beta_boot_copy' = e(beta_boot_g`_g')
                    if _rc == 0 {
                        capture matrix colnames `_bg_beta_boot_copy' = `_bg_beta_colnames'
                    }
                    capture matrix `_bg_beta_se_copy' = e(beta_se_g`_g')
                    if _rc == 0 {
                        capture matrix colnames `_bg_beta_se_copy' = `_bg_beta_colnames'
                    }
                }
            }
        }

        // Grouped replay labels the sample summary as "Obs per group", so the
        // posted tmin/tmean/tmax contract must track grouped observation
        // counts when N_by is available rather than per-firm panel length.
        local _bg_tmin = `minGroup'
        local _bg_tmean = `meanGroup'
        local _bg_tmax = `maxGroup'
        tempname _bg_sample_n_by
        local _bg_has_sample_n_by = 0
        if !`do_bootstrap' {
            capture matrix `_bg_sample_n_by' = `_bg_n_by'
            if _rc == 0 local _bg_has_sample_n_by = 1
        }
        else if `_bg_has_point_n_by' {
            capture matrix `_bg_sample_n_by' = `_bg_point_n_by'
            if _rc == 0 local _bg_has_sample_n_by = 1
        }
        if `_bg_has_sample_n_by' {
            local _bg_sample_rows = rowsof(`_bg_sample_n_by')
            local _bg_sample_cols = colsof(`_bg_sample_n_by')
            local _bg_tmin = .
            local _bg_tmax = .
            local _bg_tsum = 0
            local _bg_tcount = 0
            forvalues _bg_r = 1/`_bg_sample_rows' {
                forvalues _bg_c = 1/`_bg_sample_cols' {
                    local _bg_nobs = el(`_bg_sample_n_by', `_bg_r', `_bg_c')
                    if !missing(`_bg_nobs') {
                        if missing(`_bg_tmin') | `_bg_nobs' < `_bg_tmin' {
                            local _bg_tmin = `_bg_nobs'
                        }
                        if missing(`_bg_tmax') | `_bg_nobs' > `_bg_tmax' {
                            local _bg_tmax = `_bg_nobs'
                        }
                        local _bg_tsum = `_bg_tsum' + `_bg_nobs'
                        local _bg_tcount = `_bg_tcount' + 1
                    }
                }
            }
            if `_bg_tcount' > 0 {
                local _bg_tmean = `_bg_tsum' / `_bg_tcount'
            }
        }

        ereturn post, esample(`_pte_bg_esample') obs(`pte_bg_N')
        ereturn scalar N = `pte_bg_N'
        capture ereturn scalar sigma_eps_trim = `_bg_sigma_eps_trim'
        capture ereturn scalar sigma_eps = `_bg_sigma_eps'
        if `"`_bg_groups'"' != "" {
            ereturn local groups `"`_bg_groups'"'
        }
        if "`_bg_n_groups'" != "" {
            capture ereturn scalar n_groups = `_bg_n_groups'
        }
        if "`_bg_ngroups'" != "" {
            capture ereturn scalar ngroups = `_bg_ngroups'
        }
        if !`do_bootstrap' {
            capture ereturn matrix b_by = `_bg_b_by'
            capture ereturn matrix rho_by = `_bg_rho_by'
            capture ereturn matrix sigma_by = `_bg_sigma_by'
            if `do_att' {
                capture ereturn matrix att_by = `_bg_att_by'
                capture ereturn matrix att_pool = `_bg_att_pool'
                capture ereturn matrix att_sd = `_bg_att_sd'
                capture ereturn matrix att_N = `_bg_att_n'
                if `_bg_has_att_n_contract' {
                    capture ereturn matrix N_by_period = `_bg_att_n_by_period'
                }
            }
            capture ereturn matrix N_by = `_bg_n_by'
            capture ereturn matrix N_firms_by = `_bg_n_firms_by'
        }
        else {
            // Keep grouped point ATT paths available for predict, att without
            // advertising the full point surface to replay/display consumers.
            // Group-specific untreated-law metadata is also part of the
            // grouped public contract and must survive bootstrap reposting.
            if !missing(`_bg_group_count') {
                tempname _bg_att_boot_bygroup
                matrix `_bg_att_boot_bygroup' = J(`_bg_nboot', `_bg_group_count', .)
                local _bg_boot_cols ""
                local _bg_boot_draw_names "`_bg_att_boot_names'"
                if "`notrimeps'" == "" {
                    local _bg_boot_draw_names "`_bg_att_trim_boot_names'"
                }
                forvalues _g = 1/`_bg_group_count' {
                    local _bg_att_boot_name : word `_g' of `_bg_boot_draw_names'
                    local _bg_boot_cols "`_bg_boot_cols' g`_g'"
                    forvalues _bb = 1/`_bg_nboot' {
                        matrix `_bg_att_boot_bygroup'[`_bb', `_g'] = ///
                            el(`_bg_att_boot_name', `_bb', colsof(`_bg_att_boot_name'))
                    }
                }
                matrix colnames `_bg_att_boot_bygroup' = `_bg_boot_cols'
                capture ereturn matrix att_boot_bygroup = `_bg_att_boot_bygroup'
            }
            capture ereturn matrix att_by_point = `_bg_point_att_by'
            if `_bg_has_point_rho_by' {
                capture ereturn matrix rho_by = `_bg_point_rho_by'
            }
            if `_bg_has_point_sigma_by' {
                capture ereturn matrix sigma_by = `_bg_point_sigma_by'
            }
            if `_bg_has_point_n_by' {
                capture ereturn matrix N_by = `_bg_point_n_by'
            }
            if `_bg_has_point_n_firms_by' {
                capture ereturn matrix N_firms_by = `_bg_point_n_firms_by'
            }
            if `_bg_has_point_att_n' {
                capture ereturn matrix att_N = `_bg_point_att_n'
                capture ereturn matrix N_by_period = `_bg_point_n_by_period'
            }
            capture ereturn matrix att_boot_all = `_bg_att_boot_all'
            capture ereturn matrix att_mean_pool = `_bg_att_mean_pool'
            capture ereturn matrix att_se_pool = `_bg_att_se_pool'
            capture ereturn matrix att_ci_lower_pool = `_bg_att_ci_lo_pool'
            capture ereturn matrix att_ci_upper_pool = `_bg_att_ci_hi_pool'
            if "`notrimeps'" == "" {
                capture ereturn matrix att_boot_trim = `_bg_att_boot_trim'
                capture ereturn matrix att_mean_pool_trim = `_bg_att_mean_pool_trim'
                capture ereturn matrix att_se_pool_trim = `_bg_att_se_pool_trim'
                capture ereturn matrix att_ci_lower_trim = `_bg_att_ci_lo_trim'
                capture ereturn matrix att_ci_upper_trim = `_bg_att_ci_hi_trim'
            }
            if "`_bg_nboot'" != "" {
                capture ereturn scalar nboot = `_bg_nboot'
            }
            if "`_bg_n_success'" != "" {
                capture ereturn scalar n_success = `_bg_n_success'
            }
            if "`_bg_n_fail'" != "" {
                capture ereturn scalar n_fail = `_bg_n_fail'
            }
            if "`_bg_n_success_group'" != "" {
                capture ereturn scalar n_success_group = `_bg_n_success_group'
            }
            if "`_bg_n_fail_group'" != "" {
                capture ereturn scalar n_fail_group = `_bg_n_fail_group'
            }
            if "`_bg_industry_seed'" != "" {
                capture ereturn scalar industry_seed = `_bg_industry_seed'
            }
            if "`_bg_inner_seed'" != "" {
                capture ereturn scalar inner_seed = `_bg_inner_seed'
                capture ereturn scalar seed_inner = `_bg_inner_seed'
            }
            if `"`_bg_inner_seed_source'"' != "" {
                ereturn local inner_seed_source `"`_bg_inner_seed_source'"'
            }
            if "`_bg_parallel_method'" != "" {
                ereturn local parallel_method "`_bg_parallel_method'"
            }
            if "`_bg_parallel_nproc'" != "" {
                capture ereturn scalar parallel_nproc = `_bg_parallel_nproc'
            }
            if "`_bg_parallel_requested_nproc'" != "" {
                capture ereturn scalar parallel_requested_nproc = `_bg_parallel_requested_nproc'
            }
            if "`_bg_parallel_fallback'" != "" {
                capture ereturn scalar parallel_fallback = `_bg_parallel_fallback'
            }
            if "`_bg_parallel_helper_rc'" != "" {
                capture ereturn scalar parallel_helper_rc = `_bg_parallel_helper_rc'
            }
            if `"`_bg_parallel_requested_method'"' != "" {
                ereturn local parallel_requested_method `"`_bg_parallel_requested_method'"'
            }
            if `"`_bg_parallel_fallback_reason'"' != "" {
                ereturn local parallel_fallback_reason `"`_bg_parallel_fallback_reason'"'
            }
            if !missing(`_bg_group_count') {
                forvalues _g = 1/`_bg_group_count' {
                    local _bg_att_boot_name : word `_g' of `_bg_att_boot_names'
                    local _bg_att_trim_boot_name : word `_g' of `_bg_att_trim_boot_names'
                    local _bg_att_se_name : word `_g' of `_bg_att_se_names'
                    local _bg_beta_boot_name : word `_g' of `_bg_beta_boot_names'
                    local _bg_beta_se_name : word `_g' of `_bg_beta_se_names'
                    capture ereturn matrix att_boot_g`_g' = `_bg_att_boot_name'
                    capture ereturn matrix att_se_g`_g' = `_bg_att_se_name'
                    capture ereturn matrix beta_boot_g`_g' = `_bg_beta_boot_name'
                    capture ereturn matrix beta_se_g`_g' = `_bg_beta_se_name'
                    if "`notrimeps'" == "" {
                        capture ereturn matrix att_trim_boot_g`_g' = `_bg_att_trim_boot_name'
                    }
                }
            }
        }

        local pte_treatsig ""
        local pte_comparesig ""
        capture quietly _pte_treatment_signature, ///
            panelvar(`id') timevar(`time') treatment(`treatment')
        if _rc == 0 {
            local pte_treatsig `"`r(signature)'"'
        }
        local _pte_compare_controls_opt ""
        if `"`control'"' != "" {
            local _pte_compare_controls_opt `"controls(`control')"'
        }
        capture quietly _pte_compare_signature, ///
            panelvar(`id') timevar(`time') treatment(`treatment') ///
            depvar(`depvar') free(`free') state(`state') proxy(`proxy') ///
            `_pte_compare_controls_opt'
        if _rc == 0 {
            local pte_comparesig `"`r(signature)'"'
        }

        ereturn local cmd "pte"
        ereturn local cmdline "pte `0'"
        ereturn local title "Productivity Treatment Effects"
        ereturn local version "1.0.0"
        ereturn local method "acf"
        ereturn local model "valueadded"
        ereturn local correction "clk"
        ereturn local depvar "`depvar'"
        ereturn local free "`free'"
        ereturn local state "`state'"
        ereturn local proxy "`proxy'"
        ereturn local controls "`control'"
        ereturn local treatment "`treatment'"
        ereturn local treatsig `"`pte_treatsig'"'
        ereturn local comparesig `"`pte_comparesig'"'
        ereturn local id "`id'"
        ereturn local time "`time'"
        ereturn local panelvar "`id'"
        ereturn local idvar "`id'"
        ereturn local timevar "`time'"
        ereturn local pfunc "`pfunc'"
        ereturn local prodfunc "`pfunc'"
        ereturn local PFtype "`PFtype'"
        ereturn local by "`benchmark_by'"
        if "`industry'" != "" {
            ereturn local industry "`benchmark_by'"
        }
        if "`byindustry'" != "" | "`industry'" != "" {
            ereturn local byindustry "byindustry"
        }
        ereturn scalar noatt = !`do_att'
        ereturn scalar level = `level'
        ereturn scalar bootstrap = `bootstrap'
        ereturn scalar nsim = `nsim'
        ereturn scalar omegapoly = `omegapoly'
        ereturn scalar poly = `poly'
        ereturn scalar attperiods_max = `attperiods'
        ereturn scalar eps0window = `eps0window'
        ereturn scalar trimeps = `do_trim'
        // Keep the same sample-summary contract as the serial public path so
        // replay/sample displays do not silently lose core counts on by().
        ereturn scalar N_g = `nGroups'
        ereturn scalar N_clust = `nGroups'
        ereturn scalar tmin = `_bg_tmin'
        ereturn scalar tmean = `_bg_tmean'
        ereturn scalar tmax = `_bg_tmax'
        ereturn scalar N_treated = `N_treated'
        ereturn scalar N_control = `N_control'
        ereturn scalar N_trans = `N_trans'
        if `do_att' | `bootstrap' > 0 {
            if `bootstrap' == 0 {
                ereturn scalar seed = `seed'
            }
            else {
                ereturn scalar seed = `bygroup_boot_seed'
            }
            ereturn scalar seed_user = `seed_user'
            ereturn scalar seed_point_actual = `bygroup_point_seed'
            ereturn scalar seed_bootstrap_actual = `bygroup_boot_seed'
            if `bootstrap' == 0 {
                ereturn scalar seed_actual = `bygroup_point_seed'
            }
            else {
                ereturn scalar seed_actual = `bygroup_boot_seed'
            }
            ereturn local seed_route "grouped"
        }
        if `bootstrap' == 0 & `do_att' {
            ereturn scalar point_seed = `bygroup_point_seed'
        }
        if `do_att' | `bootstrap' > 0 {
            ereturn local seed_source "`seed_source'"
        }
        if "`replicate'" != "" {
            ereturn local replicate "`replicate'"
        }
        if `bootstrap' > 0 {
            ereturn scalar seed_outer = `bygroup_boot_seed'
            ereturn scalar bootstrap_seed = `bygroup_boot_seed'
        }
        if "`xtdelta'" != "" {
            ereturn scalar xtdelta = `xtdelta'
        }
        if "`notrimeps'" != "" {
            ereturn local notrimeps "notrimeps"
        }
        ereturn local predict "pte_p"
        if !`do_bootstrap' & `do_att' {
            tempname _bg_att _bg_att_trim _bg_att_raw _bg_attperiods
            matrix `_bg_att' = e(att_pool)
            local _bg_att_avg = el(`_bg_att', 1, `attperiods' + 2)
            if `_bg_has_att_pool_trim' {
                matrix `_bg_att_trim' = `_bg_att_pool_trim'
                local _bg_att_avg_trim = el(`_bg_att_trim', 1, `attperiods' + 2)
            }
            else {
                matrix `_bg_att_trim' = `_bg_att'
                local _bg_att_avg_trim = `_bg_att_avg'
            }
            if `_bg_has_att_pool_raw' {
                matrix `_bg_att_raw' = `_bg_att_pool_raw'
                local _bg_att_avg_raw = el(`_bg_att_raw', 1, `attperiods' + 2)
            }
            matrix `_bg_attperiods' = J(1, `attperiods' + 1, .)
            local _bg_colnames ""
            forvalues _s = 0/`attperiods' {
                matrix `_bg_attperiods'[1, `_s' + 1] = `_s'
                local _bg_colnames "`_bg_colnames' nt`_s'"
                local _bg_att_val = el(`_bg_att', 1, `_s' + 1)
                ereturn scalar att_`_s' = `_bg_att_val'
                local _bg_att_trim_val = el(`_bg_att_trim', 1, `_s' + 1)
                ereturn scalar att_trim_`_s' = `_bg_att_trim_val'
                if `_bg_has_att_pool_raw' {
                    local _bg_att_raw_val = el(`_bg_att_raw', 1, `_s' + 1)
                    ereturn scalar att_raw_`_s' = `_bg_att_raw_val'
                }
            }
            ereturn matrix att = `_bg_att'
            ereturn matrix att_trim = `_bg_att_trim'
            if `_bg_has_att_pool_raw' {
                ereturn matrix att_raw = `_bg_att_raw'
            }
            matrix colnames `_bg_attperiods' = `_bg_colnames'
            ereturn matrix attperiods = `_bg_attperiods'
            ereturn scalar ATT_avg = `_bg_att_avg'
            ereturn scalar ATT_avg_trim = `_bg_att_avg_trim'
            if `_bg_has_att_pool_raw' {
                ereturn scalar ATT_avg_raw = `_bg_att_avg_raw'
            }
        }
        else if `do_att' {
            tempname _bg_att _bg_att_raw _bg_att_trim _bg_attperiods
            tempname _bg_att_se _bg_att_ci_lo _bg_att_ci_hi
            tempname _bg_se_raw _bg_ci_lo_raw _bg_ci_hi_raw
            tempname _bg_mean_src _bg_se_src _bg_ci_lo_src _bg_ci_hi_src
            local _bg_has_trim = 0

            matrix `_bg_mean_src' = e(att_mean_pool)
            matrix `_bg_se_src' = e(att_se_pool)
            matrix `_bg_ci_lo_src' = e(att_ci_lower_pool)
            matrix `_bg_ci_hi_src' = e(att_ci_upper_pool)
            matrix `_bg_se_raw' = e(att_se_pool)
            matrix `_bg_ci_lo_raw' = e(att_ci_lower_pool)
            matrix `_bg_ci_hi_raw' = e(att_ci_upper_pool)

            if "`notrimeps'" == "" {
                capture confirm matrix e(att_mean_pool_trim)
                if _rc == 0 {
                    capture confirm matrix e(att_se_pool_trim)
                    if _rc == 0 {
                        capture confirm matrix e(att_ci_lower_trim)
                        if _rc == 0 {
                            capture confirm matrix e(att_ci_upper_trim)
                            if _rc == 0 {
                                local _bg_has_trim = 1
                                matrix `_bg_mean_src' = e(att_mean_pool_trim)
                                matrix `_bg_se_src' = e(att_se_pool_trim)
                                matrix `_bg_ci_lo_src' = e(att_ci_lower_trim)
                                matrix `_bg_ci_hi_src' = e(att_ci_upper_trim)
                            }
                        }
                    }
                }
            }

            matrix `_bg_att' = J(1, `attperiods' + 2, .)
            matrix `_bg_att_raw' = J(1, `attperiods' + 2, .)
            matrix `_bg_att_trim' = J(1, `attperiods' + 2, .)
            matrix `_bg_att_se' = J(1, `attperiods' + 2, .)
            matrix `_bg_att_ci_lo' = J(1, `attperiods' + 2, .)
            matrix `_bg_att_ci_hi' = J(1, `attperiods' + 2, .)

            matrix `_bg_att'[1, `attperiods' + 2] = `_bg_mean_src'[1, `attperiods' + 2]
            matrix `_bg_att_raw'[1, `attperiods' + 2] = e(att_mean_pool)[1, `attperiods' + 2]
            matrix `_bg_att_se'[1, `attperiods' + 2] = `_bg_se_src'[1, `attperiods' + 2]
            matrix `_bg_att_ci_lo'[1, `attperiods' + 2] = `_bg_ci_lo_src'[1, `attperiods' + 2]
            matrix `_bg_att_ci_hi'[1, `attperiods' + 2] = `_bg_ci_hi_src'[1, `attperiods' + 2]
            if `_bg_has_trim' {
                matrix `_bg_att_trim'[1, `attperiods' + 2] = e(att_mean_pool_trim)[1, `attperiods' + 2]
            }
            else {
                matrix `_bg_att_trim'[1, `attperiods' + 2] = `_bg_mean_src'[1, `attperiods' + 2]
            }

            local _bg_att_avg = el(`_bg_mean_src', 1, `attperiods' + 2)
            local _bg_att_avg_raw = el(`_bg_att_raw', 1, `attperiods' + 2)
            local _bg_colnames ""
            forvalues _s = 0/`attperiods' {
                local _src = `_s' + 1
                local _bg_colnames "`_bg_colnames' nt`_s'"
                matrix `_bg_att'[1, `_s' + 1] = `_bg_mean_src'[1, `_src']
                matrix `_bg_att_raw'[1, `_s' + 1] = e(att_mean_pool)[1, `_src']
                matrix `_bg_att_se'[1, `_s' + 1] = `_bg_se_src'[1, `_src']
                matrix `_bg_att_ci_lo'[1, `_s' + 1] = `_bg_ci_lo_src'[1, `_src']
                matrix `_bg_att_ci_hi'[1, `_s' + 1] = `_bg_ci_hi_src'[1, `_src']
                local _bg_att_val = el(`_bg_mean_src', 1, `_src')
                local _bg_se_val = el(`_bg_se_src', 1, `_src')
                local _bg_ci_lo_val = el(`_bg_ci_lo_src', 1, `_src')
                local _bg_ci_hi_val = el(`_bg_ci_hi_src', 1, `_src')
                local _bg_se_raw_val = el(`_bg_se_raw', 1, `_src')
                local _bg_ci_lo_raw_val = el(`_bg_ci_lo_raw', 1, `_src')
                local _bg_ci_hi_raw_val = el(`_bg_ci_hi_raw', 1, `_src')
                ereturn scalar att_`_s' = `_bg_att_val'
                if `_bg_has_trim' {
                    matrix `_bg_att_trim'[1, `_s' + 1] = e(att_mean_pool_trim)[1, `_src']
                }
                else {
                    matrix `_bg_att_trim'[1, `_s' + 1] = `_bg_mean_src'[1, `_src']
                }
                ereturn scalar bs_se_`_s' = `_bg_se_val'
                ereturn scalar ci_lo_`_s' = `_bg_ci_lo_val'
                ereturn scalar ci_hi_`_s' = `_bg_ci_hi_val'
                ereturn scalar bs_se_raw_`_s' = `_bg_se_raw_val'
                ereturn scalar ci_lo_raw_`_s' = `_bg_ci_lo_raw_val'
                ereturn scalar ci_hi_raw_`_s' = `_bg_ci_hi_raw_val'
                if `_bg_has_trim' {
                    local _bg_att_trim_val = el(`_bg_mean_src', 1, `_src')
                    local _bg_att_raw_val = el(`_bg_att_raw', 1, `_s' + 1)
                    ereturn scalar att_trim_`_s' = `_bg_att_trim_val'
                    ereturn scalar att_raw_`_s' = `_bg_att_raw_val'
                }
                else {
                    local _bg_att_trim_val = el(`_bg_att_trim', 1, `_s' + 1)
                    local _bg_att_raw_val = el(`_bg_att_raw', 1, `_s' + 1)
                    ereturn scalar att_trim_`_s' = `_bg_att_trim_val'
                    ereturn scalar att_raw_`_s' = `_bg_att_raw_val'
                }
            }
            matrix colnames `_bg_att' = `_bg_colnames' ATT_avg
            matrix colnames `_bg_att_raw' = `_bg_colnames' ATT_avg
            matrix colnames `_bg_att_se' = `_bg_colnames' ATT_avg
            matrix colnames `_bg_att_ci_lo' = `_bg_colnames' ATT_avg
            matrix colnames `_bg_att_ci_hi' = `_bg_colnames' ATT_avg
            matrix colnames `_bg_att_trim' = `_bg_colnames' ATT_avg
            ereturn matrix att = `_bg_att'
            ereturn matrix att_se = `_bg_att_se'
            ereturn matrix att_ci_lower = `_bg_att_ci_lo'
            ereturn matrix att_ci_upper = `_bg_att_ci_hi'
            ereturn matrix att_trim = `_bg_att_trim'
            ereturn matrix att_raw = `_bg_att_raw'
            matrix `_bg_attperiods' = J(1, `attperiods' + 1, .)
            forvalues _s = 0/`attperiods' {
                matrix `_bg_attperiods'[1, `_s' + 1] = `_s'
            }
            matrix colnames `_bg_attperiods' = `_bg_colnames'
            ereturn matrix attperiods = `_bg_attperiods'
            ereturn scalar ATT_avg = `_bg_att_avg'
            if `_bg_has_trim' {
                local _bg_att_avg_trim = el(`_bg_mean_src', 1, `attperiods' + 2)
                ereturn scalar ATT_avg_raw = `_bg_att_avg_raw'
                local _bg_bs_se_trim = el(`_bg_se_src', 1, `attperiods' + 2)
                local _bg_ci_lo_trim = el(`_bg_ci_lo_src', 1, `attperiods' + 2)
                local _bg_ci_hi_trim = el(`_bg_ci_hi_src', 1, `attperiods' + 2)
                ereturn scalar ATT_avg_trim = `_bg_att_avg_trim'
                ereturn scalar bs_se_trim = `_bg_bs_se_trim'
                ereturn scalar ci_lo_trim = `_bg_ci_lo_trim'
                ereturn scalar ci_hi_trim = `_bg_ci_hi_trim'
            }
            else {
                local _bg_att_avg_trim = `_bg_att_avg'
                ereturn scalar ATT_avg_raw = `_bg_att_avg_raw'
                ereturn scalar ATT_avg_trim = `_bg_att_avg_trim'
                ereturn scalar bs_se_trim = el(`_bg_se_src', 1, `attperiods' + 2)
                ereturn scalar ci_lo_trim = el(`_bg_ci_lo_src', 1, `attperiods' + 2)
                ereturn scalar ci_hi_trim = el(`_bg_ci_hi_src', 1, `attperiods' + 2)
            }
            local _bg_bs_se = el(`_bg_se_src', 1, `attperiods' + 2)
            local _bg_ci_lo = el(`_bg_ci_lo_src', 1, `attperiods' + 2)
            local _bg_ci_hi = el(`_bg_ci_hi_src', 1, `attperiods' + 2)
            local _bg_bs_se_raw = el(`_bg_se_raw', 1, `attperiods' + 2)
            local _bg_ci_lo_raw = el(`_bg_ci_lo_raw', 1, `attperiods' + 2)
            local _bg_ci_hi_raw = el(`_bg_ci_hi_raw', 1, `attperiods' + 2)
            ereturn scalar bs_se = `_bg_bs_se'
            ereturn scalar ci_lo = `_bg_ci_lo'
            ereturn scalar ci_hi = `_bg_ci_hi'
            ereturn scalar bs_se_raw = `_bg_bs_se_raw'
            ereturn scalar ci_lo_raw = `_bg_ci_lo_raw'
            ereturn scalar ci_hi_raw = `_bg_ci_hi_raw'
        }

        // Match the serial public contract: estimation-progress chatter may
        // differ from replay, but the live grouped path must still end on the
        // same public result summary produced from the reposted e() bundle.
        _pte_display, `noatt' level(`level') `verbose'
        exit
    }


    // Emit the banner only after validation so early failures stay concise.
    if "`nolog'" == "" {
        if "`verbose'" != "" {
            di as text ""
            di as text "{hline 70}"
            di as text "Productivity Treatment Effects (PTE)"
            di as text "Chen, Liao & Schurter (2026)"
            di as text "{hline 70}"
            di as text "  Dependent variable:   " as result "`depvar'"
            di as text "  Free variable:        " as result "`free'"
            di as text "  State variable:       " as result "`state'"
            di as text "  Proxy variable:       " as result "`proxy'"
            di as text "  Treatment variable:   " as result "`treatment'"
            di as text "  Panel:                " as result "`id' x `time'"
            di as text "  Production function:  " as result "`PFtype'"
            di as text "  Polynomial order:     " as result "`poly'"
            di as text "  Evolution order:      " as result "`omegapoly'"
            if `eps0window' == 0 {
                di as text "  eps0 window:          " as result "all pre-treatment"
            }
            else {
                di as text "  eps0 window:          " as result "`eps0window'" as text " panel periods"
            }
            if `do_att' {
                di as text "  ATT periods:          " as result "0 to `attperiods'"
                di as text "  Simulation paths:     " as result "`nsim'"
                if `do_bootstrap' {
                    di as text "  Outer bootstrap seed: " as result "`seed'"
                    di as text "  ATT simulation seed:  " as result "`att_bootstrap_seed' (fixed)"
                }
                else {
                    di as text "  ATT simulation seed:  " as result "`att_point_seed' (fixed)"
                }
                di as text "  Trim eps0:            " as result cond(`do_trim', "Yes (1%-99%)", "No")
            }
            else {
                di as text "  ATT estimation:       " as result "Skipped (noatt)"
            }
            if `do_bootstrap' {
                di as text "  Bootstrap reps:       " as result "`bootstrap'"
                di as text "  Confidence level:     " as result "`level'%"
            }
            if `is_replicate' {
                di as text "  Replicate mode:       " as result "`replicate'"
            }
            di as text "{hline 70}"
        }
        else {
            * Compact progress header
            local _pfunc_label = cond("`pfunc'" == "cd", "Cobb-Douglas", "Translog")
            display ""
            display as text "{hline 70}"
            display as text " Productivity Treatment Effects (PTE) {c -} " as result "`_pfunc_label'"
            display as text "{hline 70}"
        }
    }

    // Load Mata libraries before any estimator runs. Otherwise failures can
    // surface deep in the pipeline with poor diagnostics.
    if "`verbose'" != "" {
        capture noisily _pte_mata_init, verbose
    }
    else {
        capture noisily _pte_mata_init, nolog
    }
    if _rc != 0 {
        _pte_error, errcode(601) ///
            msg("Mata function initialization failed") ///
            suggestion("Try: _pte_mata_init, force verbose")
    }

    // Later stages expand, merge, and resample the panel. A tempfile copy is
    // the recovery anchor for restoring the caller's original data state.
    tempfile _pte_orig_data
    quietly save `_pte_orig_data', replace

    // Stage 1 estimates the production function and publishes fitted objects
    // needed by productivity recovery and ATT simulation.
    if "`nolog'" == "" {
        if "`verbose'" != "" {
            di as text ""
            di as text "Step 1/4: Production Function Estimation (Theorem 3.1)"
            di as text "{hline 70}"
        }
        else {
            display as text "  Step 1/4: Production function estimation..." _continue
        }
    }

    // Public pte reruns must be idempotent over package-owned transition
    // helpers left in memory by a previous successful run. Only recycle the
    // reserved _pte_* helper and legacy aliases when their package labels
    // match, so user-owned generic columns are not dropped implicitly.
    capture confirm variable _pte_mid, exact
    if _rc == 0 {
        capture drop _pte_mid

        capture confirm variable mid, exact
        if _rc == 0 {
            local _pte_mid_label : variable label mid
            if `"`_pte_mid_label'"' == "Legacy alias for _pte_mid" {
                capture drop mid
            }
        }

        capture confirm variable G, exact
        if _rc == 0 {
            local _pte_G_label : variable label G
            if `"`_pte_G_label'"' == "Treatment switch indicator (-1/0/+1)" {
                capture drop G
            }
        }

        capture confirm variable mid_lag, exact
        if _rc == 0 {
            local _pte_mid_lag_label : variable label mid_lag
            if `"`_pte_mid_lag_label'"' == "Lagged transition period indicator" {
                capture drop mid_lag
            }
        }
    }

    // Build the canonical option bundle once so the helper sees the validated
    // main-command state.
    local _pf_opts "treatment(`treatment') id(`id') time(`time')"
    local _pf_opts "`_pf_opts' lny(`depvar') free(`free') state(`state') proxy(`proxy')"
    local _pf_opts "`_pf_opts' pfunc(`pfunc') poly(`poly') omegapoly(`omegapoly')"
    local _pf_opts "`_pf_opts' touse(`_pte_touse')"
    if "`control'" != "" {
        local _pf_opts "`_pf_opts' control(`control')"
    }
    if "`nodiagnose'" != "" {
        local _pf_opts "`_pf_opts' nodiagnose"
    }
    if "`nolog'" != "" | "`verbose'" == "" {
        local _pf_opts "`_pf_opts' noreport"
    }
    if "`treatdependent'" != "" {
        local _pf_opts "`_pf_opts' treatdependent"
    }
    if "`_pte_benchmark_ttrendby'" != "" {
        local _pf_opts "`_pf_opts' ttrendby(`_pte_benchmark_ttrendby')"
    }
    if "`_pte_benchmark_ttrendvars'" != "" {
        local _pf_opts "`_pf_opts' ttrendvars(`_pte_benchmark_ttrendvars')"
    }
    if `replicate_legacy_pooled_eps0' {
        local _pf_opts "`_pf_opts' legacyfloatphi"
    }
    if `is_replicate' {
        local _pf_opts "`_pf_opts' dopooledz"
    }

    if "`verbose'" == "" & "`nolog'" == "" {
        capture _pte_prodfunc, `_pf_opts'
    }
    else {
        capture noisily _pte_prodfunc, `_pf_opts'
    }
    local _pf_rc = _rc
    if `_pf_rc' != 0 {
        quietly use `_pte_orig_data', clear
        if `_pte_has_prev_est' {
            capture estimates restore `_pte_prev_est'
            capture estimates drop `_pte_prev_est'
            local _pte_has_prev_est = 0
        }
        else {
            capture ereturn clear
        }
        _pte_error, errcode(`_pf_rc') ///
            msg("Production function estimation failed (rc = `_pf_rc')")
    }

    if "`verbose'" == "" & "`nolog'" == "" {
        local _fval = e(fval)
        if "`_fval'" != "" & "`_fval'" != "." {
            display as result " done (fval = " %8.2e `_fval' ")"
        }
        else {
            display as result " done"
        }
    }

    // Cache stage-1 coefficients locally because later calls overwrite _b.
    local pf_beta_l = _b[`free']
    local pf_beta_k = _b[`state']
    if "`pfunc'" == "translog" {
        local pf_beta_ll = _b[l2]
        local pf_beta_kk = _b[k2]
        local pf_beta_lk = _b[l1k1]
    }

    // Preserve selected stage-1 scalars for the final e() bundle.
    local pf_N = e(N)
    local pf_N_gmm = e(N_gmm)
    capture local pf_fval = e(fval)
    capture local pf_converged = e(converged)
    capture local pf_iterations = e(iterations)
    capture local pf_z_moment_layout = e(z_moment_layout)
    capture local pf_do_pooled_z = e(do_pooled_z)
    local pf_has_beta_controls = 0
    local pf_n_beta_controls = 0
    tempname pf_beta_controls_mat
    capture matrix `pf_beta_controls_mat' = e(beta_controls)
    if _rc == 0 {
        local pf_has_beta_controls = 1
        local pf_n_beta_controls = colsof(`pf_beta_controls_mat')
        if `pf_n_beta_controls' == 1 {
            local pf_beta_t = `pf_beta_controls_mat'[1, 1]
        }
    }
    tempvar _pte_pf_esample_live
    quietly gen byte `_pte_pf_esample_live' = e(sample)


    // Stage 2 recovers omega, estimates the state-specific evolution laws, and
    // constructs the eps0 objects used in the counterfactual simulator.
    if "`nolog'" == "" {
        if "`verbose'" != "" {
            di as text ""
            di as text "Step 2/4: Productivity Recovery and Evolution"
            di as text "{hline 70}"
        }
        else {
            display as text "  Step 2/4: Productivity recovery..." _continue
        }
    }

    tempname rho_0_mat
    local om_has_rho_1 = 0
    local om_has_gamma1 = 0
    local om_has_gamma2 = 0
    local om_has_gamma3 = 0
    local om_has_gamma4 = 0
    local om_has_delta = 0
    if "`treatdependent'" != "" {
        local _td_omega_opts ""
        if "`nodiagnose'" != "" {
            local _td_omega_opts "nodiagnose"
        }

        if "`verbose'" == "" & "`nolog'" == "" {
            capture _pte_treatdep_omega, `_td_omega_opts'
        }
        else {
            capture noisily _pte_treatdep_omega, `_td_omega_opts'
        }
        local _om_rc = _rc
        if `_om_rc' != 0 {
            quietly use `_pte_orig_data', clear
            if `_pte_has_prev_est' {
                capture estimates restore `_pte_prev_est'
                capture estimates drop `_pte_prev_est'
                local _pte_has_prev_est = 0
            }
            else {
                capture ereturn clear
            }
            _pte_error, errcode(`_om_rc') ///
                msg("Treatment-dependent omega recovery failed (rc = `_om_rc')")
        }

        quietly count if `_pte_touse' & !missing(omega)
        local om_N_omega = r(N)

        local _td_evo_opts "treatment(`treatment') omegapoly(`omegapoly') touse(`_pte_touse')"
        if "`nodiagnose'" != "" {
            local _td_evo_opts "`_td_evo_opts' nodiagnose"
        }

        if "`verbose'" == "" & "`nolog'" == "" {
            capture _pte_treatdep_evolution, `_td_evo_opts'
        }
        else {
            capture noisily _pte_treatdep_evolution, `_td_evo_opts'
        }
        local _td_evo_rc = _rc
        if `_td_evo_rc' != 0 {
            quietly use `_pte_orig_data', clear
            if `_pte_has_prev_est' {
                capture estimates restore `_pte_prev_est'
                capture estimates drop `_pte_prev_est'
                local _pte_has_prev_est = 0
            }
            else {
                capture ereturn clear
            }
            _pte_error, errcode(`_td_evo_rc') ///
                msg("Treatment-dependent evolution failed (rc = `_td_evo_rc')")
        }

        local om_N_evo = e(N_evo)
        local om_r2_evo = e(r2)
        local om_rmse_evo = e(rmse)
        local om_N_lag_untreated = e(N_lag_untreated)
        local om_N_lag_treated = e(N_lag_treated)
        local om_lag_treated_supported = e(lag_treated_supported)
        local om_rho0 = e(rho0)
        local om_rho1 = e(rho1)
        if `omegapoly' >= 2 local om_rho2 = e(rho2)
        if `omegapoly' >= 3 local om_rho3 = e(rho3)
        if `omegapoly' >= 4 local om_rho4 = e(rho4)
        matrix `rho_0_mat' = e(rho_0)
        capture confirm matrix e(rho_1)
        if _rc == 0 {
            tempname rho_1_mat
            matrix `rho_1_mat' = e(rho_1)
            local om_has_rho_1 = 1
        }
        capture confirm scalar e(gamma1)
        if _rc == 0 {
            local om_gamma1 = e(gamma1)
            local om_has_gamma1 = 1
        }
        if `omegapoly' >= 2 {
            capture confirm scalar e(gamma2)
            if _rc == 0 {
                local om_gamma2 = e(gamma2)
                local om_has_gamma2 = 1
            }
        }
        if `omegapoly' >= 3 {
            capture confirm scalar e(gamma3)
            if _rc == 0 {
                local om_gamma3 = e(gamma3)
                local om_has_gamma3 = 1
            }
        }
        if `omegapoly' >= 4 {
            capture confirm scalar e(gamma4)
            if _rc == 0 {
                local om_gamma4 = e(gamma4)
                local om_has_gamma4 = 1
            }
        }
        capture confirm scalar e(delta)
        if _rc == 0 {
            local om_delta = e(delta)
            local om_has_delta = 1
        }

        local _td_eps_opts "treatment(`treatment') eps0window(`eps0window') touse(`_pte_touse')"
        if "`nodiagnose'" != "" {
            local _td_eps_opts "`_td_eps_opts' nodiagnose"
        }

        if "`verbose'" == "" & "`nolog'" == "" {
            capture _pte_eps0_sample, `_td_eps_opts'
        }
        else {
            capture noisily _pte_eps0_sample, `_td_eps_opts'
        }
        local _td_eps_rc = _rc
        if `_td_eps_rc' != 0 {
            quietly use `_pte_orig_data', clear
            if `_pte_has_prev_est' {
                capture estimates restore `_pte_prev_est'
                capture estimates drop `_pte_prev_est'
                local _pte_has_prev_est = 0
            }
            else {
                capture ereturn clear
            }
            _pte_error, errcode(`_td_eps_rc') ///
                msg("eps0 sample selection failed on treatdependent path (rc = `_td_eps_rc')")
        }

        local _td_win_opts ""
        if "`notrimeps'" != "" {
            local _td_win_opts "`_td_win_opts' notrimeps"
        }
        if "`nodiagnose'" != "" {
            local _td_win_opts "`_td_win_opts' nodiagnose"
        }

        if "`verbose'" == "" & "`nolog'" == "" {
            capture _pte_winsorize, `_td_win_opts'
        }
        else {
            capture noisily _pte_winsorize, `_td_win_opts'
        }
        local _td_win_rc = _rc
        if `_td_win_rc' != 0 {
            quietly use `_pte_orig_data', clear
            if `_pte_has_prev_est' {
                capture estimates restore `_pte_prev_est'
                capture estimates drop `_pte_prev_est'
                local _pte_has_prev_est = 0
            }
            else {
                capture ereturn clear
            }
            _pte_error, errcode(`_td_win_rc') ///
                msg("eps0 distribution estimation failed on treatdependent path (rc = `_td_win_rc')")
        }

        local om_sigma_eps = e(sigma_eps)
        local om_sigma_eps_trim = e(sigma_eps_trim)
        local om_trimeps = e(trimeps)
        local om_N_eps0 = e(N_eps0)
        local om_N_eps0_trim = e(N_eps0_trim)
        local om_eps0_p1 = e(eps0_p1)
        local om_eps0_p99 = e(eps0_p99)
        local om_eps0window = `eps0window'
        local om_legacy_pooled_eps0 = 0

        if "`verbose'" == "" & "`nolog'" == "" {
            display as result " done"
        }
    }
    else {
        // Forward only the options that affect omega recovery and evolution.
        local _om_opts "treatment(`treatment') omegapoly(`omegapoly')"
        local _om_opts "`_om_opts' beta_l(`pf_beta_l') beta_k(`pf_beta_k')"
        local _om_opts "`_om_opts' eps0window(`eps0window')"
        local _om_opts "`_om_opts' touse(`_pte_touse')"
        if "`pfunc'" == "translog" {
            local _om_opts "`_om_opts' beta_ll(`pf_beta_ll') beta_kk(`pf_beta_kk') beta_lk(`pf_beta_lk')"
            local _om_opts "`_om_opts' prodfunc(translog)"
        }
        if "`notrimeps'" != "" {
            local _om_opts "`_om_opts' notrimeps"
        }
        if `replicate_legacy_pooled_eps0' {
            local _om_opts "`_om_opts' legacypooledeps0"
            local _om_opts "`_om_opts' legacyfloatomega"
        }
        if "`nodiagnose'" != "" {
            local _om_opts "`_om_opts' nodiagnose"
        }

        if "`verbose'" == "" & "`nolog'" == "" {
            capture _pte_omega, `_om_opts'
        }
        else {
            capture noisily _pte_omega, `_om_opts'
        }
        local _om_rc = _rc
        if `_om_rc' != 0 {
            quietly use `_pte_orig_data', clear
            if `_pte_has_prev_est' {
                capture estimates restore `_pte_prev_est'
                capture estimates drop `_pte_prev_est'
                local _pte_has_prev_est = 0
            }
            else {
                capture ereturn clear
            }
            _pte_error, errcode(`_om_rc') ///
                msg("Productivity recovery failed (rc = `_om_rc')")
        }

        if "`verbose'" == "" & "`nolog'" == "" {
            display as result " done"
        }

        // Preserve stage-2 scalars before later estimation steps overwrite e().
        local om_sigma_eps = e(sigma_eps)
        local om_sigma_eps_trim = e(sigma_eps_trim)
        local om_trimeps = e(trimeps)
        local om_N_omega = e(N_omega)
        local om_N_evo = e(N_evo)
        local om_N_eps0 = e(N_eps0)
        local om_N_eps0_trim = e(N_eps0_trim)
        local om_eps0_p1 = e(eps0_p1)
        local om_eps0_p99 = e(eps0_p99)
        local om_eps0window = e(eps0window)
        local om_legacy_pooled_eps0 = e(legacy_pooled_eps0)
        local om_r2_evo = e(r2_evo)
        local om_rmse_evo = e(rmse_evo)
        local om_N_lag_untreated = e(N_lag_untreated)
        local om_N_lag_treated = e(N_lag_treated)
        local om_lag_treated_supported = e(lag_treated_supported)
        local om_rho0 = e(rho0)
        local om_rho1 = e(rho1)
        if `omegapoly' >= 2 local om_rho2 = e(rho2)
        if `omegapoly' >= 3 local om_rho3 = e(rho3)
        if `omegapoly' >= 4 local om_rho4 = e(rho4)
        matrix `rho_0_mat' = e(rho_0)
        capture confirm matrix e(rho_1)
        if _rc == 0 {
            tempname rho_1_mat
            matrix `rho_1_mat' = e(rho_1)
            local om_has_rho_1 = 1
        }
        capture confirm scalar e(gamma1)
        if _rc == 0 {
            local om_gamma1 = e(gamma1)
            local om_has_gamma1 = 1
        }
        if `omegapoly' >= 2 {
            capture confirm scalar e(gamma2)
            if _rc == 0 {
                local om_gamma2 = e(gamma2)
                local om_has_gamma2 = 1
            }
        }
        if `omegapoly' >= 3 {
            capture confirm scalar e(gamma3)
            if _rc == 0 {
                local om_gamma3 = e(gamma3)
                local om_has_gamma3 = 1
            }
        }
        if `omegapoly' >= 4 {
            capture confirm scalar e(gamma4)
            if _rc == 0 {
                local om_gamma4 = e(gamma4)
                local om_has_gamma4 = 1
            }
        }
        capture confirm scalar e(delta)
        if _rc == 0 {
            local om_delta = e(delta)
            local om_has_delta = 1
        }
    }

    // Persist latent objects under stable _pte_* names because restore/use
    // discards the helper-specific names created inside estimation stages.
    tempfile _pte_internal_vars
    preserve
    local _keep_vars "`id' `time' `_pte_pf_esample_live'"
    // Keep only objects that were actually generated on this path.
    foreach _v in phi omega _pte_mid mid _pte_eps0 _pte_eps0_trim _pte_eps0_ind _pte_active_sample {
        capture confirm variable `_v'
        if _rc == 0 {
            local _keep_vars "`_keep_vars' `_v'"
        }
    }
    // Stage 1 may synthesize grouped time-trend controls (_pte_t, _pte_t#)
    // and publish them through e(beta_controls). If the public command keeps
    // the coefficient contract but drops those generated columns on restore,
    // downstream verify/direct-method consumers see a broken public state.
    if `pf_has_beta_controls' {
        local _pte_ctrl_keep : colnames `pf_beta_controls_mat'
        foreach _pte_ctrl of local _pte_ctrl_keep {
            if strpos("`_pte_ctrl'", "_pte_") == 1 {
                capture confirm variable `_pte_ctrl', exact
                if _rc == 0 {
                    local _keep_vars "`_keep_vars' `_pte_ctrl'"
                }
            }
        }
    }
    // predict/diagnose needs both the realized treatment path D_it and the
    // firm-level ever-treated indicator.
    capture confirm variable `treatment'
    if _rc == 0 {
        local _keep_vars "`_keep_vars' `treatment'"
    }
    quietly keep `_keep_vars'
    // Normalize variable names for postestimation helpers.
    capture rename phi _pte_phi
    capture rename omega _pte_omega
    capture confirm variable _pte_mid, exact
    if _rc {
        di as error "[pte] exact internal helper _pte_mid is missing after publication"
        di as error "[pte] public postestimation state must not be reconstructed from legacy mid"
        exit 111
    }
    capture confirm variable `treatment'
    if _rc == 0 {
        tempvar _pte_treat_firm
        quietly bysort `id': egen byte `_pte_treat_firm' = max(`treatment')
        quietly gen byte _pte_D = `treatment'
        quietly gen byte _pte_treat = (`_pte_treat_firm' > 0) if !missing(`_pte_treat_firm')
        quietly drop `_pte_treat_firm'
        quietly drop `treatment'
    }
    // Track the stable internal state names that must dominate any
    // same-named user columns when we merge back into the untouched panel.
    local _pte_merge_shadow_vars "_pte_phi _pte_omega _pte_mid _pte_eps0 _pte_eps0_trim _pte_eps0_ind _pte_active_sample _pte_D _pte_treat"
    // ATT-owned live state must be replaced by the current run's published
    // bundle, including the case where noatt intentionally publishes nothing.
    // Otherwise a noatt rerun inherits stale ATT objects from the pre-run data
    // even though the public e(noatt)=1 contract says ATT was skipped.
    local _pte_merge_shadow_vars "`_pte_merge_shadow_vars' _pte_treat_year treat_yr0 _pte_nt _pte_omega_0 _pte_omega_0_trim _pte_tt_raw _pte_tt _pte_tt_trim _pte_eps0_draw _pte_eps0_trim_draw _pte_tt_raw_sd _pte_tt_sd _pte_tt_trim_sd"
    if `pf_has_beta_controls' {
        foreach _pte_ctrl of local _pte_ctrl_keep {
            if strpos("`_pte_ctrl'", "_pte_") == 1 {
                local _pte_merge_shadow_vars "`_pte_merge_shadow_vars' `_pte_ctrl'"
            }
        }
    }
    quietly save `_pte_internal_vars', replace
    restore

    // Stage 3 either computes ATT directly or delegates the whole pipeline to
    // the bootstrap worker for repeated estimation.

    if `do_att' {
        if `do_bootstrap' {
            // Bootstrap reruns the full estimator, including the point estimate.
            if "`nolog'" == "" {
                if "`verbose'" != "" {
                    di as text ""
                    di as text "Step 3-4/4: Bootstrap ATT Estimation and Inference"
                    di as text "{hline 70}"
                }
                else {
                    display as text "  Step 3/4: Bootstrap ATT estimation (" as result "`bootstrap' reps" as text ")..." _continue
                }
            }

            // Restore the untouched panel before the bootstrap worker resamples.
            quietly use `_pte_orig_data', clear
            quietly xtset `id' `time' `_pte_xtset_delta_opt'

            // Forward the validated state to the bootstrap worker.
            local _bs_opts "treatment(`treatment')"
            local _bs_opts "`_bs_opts' depvar(`depvar') free(`free') state(`state') proxy(`proxy')"
            local _bs_opts "`_bs_opts' id(`id') time(`time')"
            local _bs_opts "`_bs_opts' omegapoly(`omegapoly') attperiods(`attperiods')"
            local _bs_opts "`_bs_opts' nsim(`nsim') breps(`bootstrap') seed(`seed') inner_seed(`att_bootstrap_seed') eps0window(`eps0window')"
            local _bs_opts "`_bs_opts' prodfunc(`pfunc') poly(`poly') level(`level')"
            local _bs_opts "`_bs_opts' touse(`_pte_touse')"
            if "`notrimeps'" != "" {
                local _bs_opts "`_bs_opts' notrimeps"
            }
            if "`nodiagnose'" != "" {
                local _bs_opts "`_bs_opts' nodiagnose"
            }
            if "`saving'" != "" {
                local _bs_opts "`_bs_opts' saving(`saving')"
            }
            if `is_replicate' {
                local _bs_opts "`_bs_opts' replicate"
                local _bs_opts "`_bs_opts' dopooledz"
            }
            if "`_pte_benchmark_ttrendby'" != "" {
                local _bs_opts "`_bs_opts' ttrendby(`_pte_benchmark_ttrendby')"
            }
            if "`_pte_benchmark_ttrendvars'" != "" {
                local _bs_opts "`_bs_opts' ttrendvars(`_pte_benchmark_ttrendvars')"
            }
            if `replicate_legacy_pooled_eps0' {
                local _bs_opts "`_bs_opts' legacypooledeps0"
            }
            if "`verbose'" == "" & "`nolog'" == "" {
                local _bs_opts "`_bs_opts' nolog"
            }

            capture noisily _pte_bootstrap, `_bs_opts'
            local _bs_rc = _rc
            if `_bs_rc' != 0 {
                quietly use `_pte_orig_data', clear
                quietly xtset `id' `time' `_pte_xtset_delta_opt'
                if `_pte_has_prev_est' {
                    capture estimates restore `_pte_prev_est'
                    capture estimates drop `_pte_prev_est'
                    local _pte_has_prev_est = 0
                }
                else {
                    capture ereturn clear
                }
                _pte_error, errcode(`_bs_rc') ///
                    msg("Bootstrap inference failed (rc = `_bs_rc')")
            }

            if "`verbose'" == "" & "`nolog'" == "" {
                display as result " done"
            }

            capture local att_bootstrap_seed = e(inner_seed)
            if _rc != 0 | missing(`att_bootstrap_seed') {
                local att_bootstrap_seed = `att_inner_seed'
            }
            local bs_seed_outer_strategy ""
            capture local bs_seed_outer_strategy `"`e(seed_outer_strategy)'"'
            if _rc != 0 | `"`bs_seed_outer_strategy'"' == "." {
                local bs_seed_outer_strategy ""
            }
            local bs_inner_seed_source ""
            capture local bs_inner_seed_source `"`e(inner_seed_source)'"'
            if _rc != 0 | `"`bs_inner_seed_source'"' == "." {
                local bs_inner_seed_source ""
            }

            // _pte_bootstrap follows the row-vector contract for e(att),
            // so the pooled scalars come from the explicit ATT_avg* aliases.
            local att_overall = e(ATT_avg)
            capture local att_raw_overall = e(ATT_avg_raw)
            if _rc != 0 local att_raw_overall = .
            capture local att_cf_missing_unexpected = e(N_cf_missing_unexpected)
            if _rc != 0 local att_cf_missing_unexpected = .
            capture local att_cf_trim_missing_unexpected = e(N_cf_trim_missing_unexpected)
            if _rc != 0 local att_cf_trim_missing_unexpected = .
            local att_se = e(bs_se)
            local att_ci_lo = e(ci_lo)
            local att_ci_hi = e(ci_hi)
            capture local att_raw_se = e(bs_se_raw)
            if _rc != 0 local att_raw_se = .
            capture local att_raw_ci_lo = e(ci_lo_raw)
            if _rc != 0 local att_raw_ci_lo = .
            capture local att_raw_ci_hi = e(ci_hi_raw)
            if _rc != 0 local att_raw_ci_hi = .
            local bs_n_success = e(n_success)
            local bs_n_fail = e(n_fail)

            local att_trim_overall = e(ATT_avg_trim)
            local att_trim_se = e(bs_se_trim)
            local att_trim_ci_lo = e(ci_lo_trim)
            local att_trim_ci_hi = e(ci_hi_trim)

            // Dynamic ATT paths are returned separately from the scalar ATT.
            forvalues s = 0/`attperiods' {
                capture local att_`s' = e(att_`s')
                if _rc != 0 local att_`s' = .
                capture local att_se_`s' = e(bs_se_`s')
                if _rc != 0 local att_se_`s' = .
                capture local att_ci_lo_`s' = e(ci_lo_`s')
                if _rc != 0 local att_ci_lo_`s' = .
                capture local att_ci_hi_`s' = e(ci_hi_`s')
                if _rc != 0 local att_ci_hi_`s' = .
                capture local att_trim_`s' = e(att_trim_`s')
                if _rc != 0 local att_trim_`s' = .
                capture local att_raw_`s' = e(att_raw_`s')
                if _rc != 0 local att_raw_`s' = .
                capture local att_raw_se_`s' = e(bs_se_raw_`s')
                if _rc != 0 local att_raw_se_`s' = .
                capture local att_raw_ci_lo_`s' = e(ci_lo_raw_`s')
                if _rc != 0 local att_raw_ci_lo_`s' = .
                capture local att_raw_ci_hi_`s' = e(ci_hi_raw_`s')
                if _rc != 0 local att_raw_ci_hi_`s' = .
            }

            // Preserve the raw bootstrap draws for postestimation summaries.
            tempname bs_raw_mat bs_betas_mat rtab_raw_mat
            matrix `bs_raw_mat' = e(bs_raw)
            matrix `bs_betas_mat' = e(bs_betas)
            matrix `rtab_raw_mat' = e(result_table_raw)
            if `do_trim' {
                tempname bs_trim_mat rtab_trim_mat
                matrix `bs_trim_mat' = e(bs_trim)
                matrix `rtab_trim_mat' = e(result_table_trim)
            }
            // Preserve period-specific standard errors and confidence bounds.
            tempname bs_att_mat bs_att_trim_mat bs_att_raw_mat bs_attperiods_mat
            tempname bs_att_se_mat bs_att_ci_lo_mat bs_att_ci_hi_mat
            tempname bs_att_lb_mat bs_att_ub_mat bs_n_by_period_mat
            matrix `bs_att_mat' = e(att)
            matrix `bs_att_trim_mat' = e(att_trim)
            matrix `bs_att_raw_mat' = e(att_raw)
            matrix `bs_attperiods_mat' = e(attperiods)
            matrix `bs_att_se_mat' = e(att_se)
            matrix `bs_att_ci_lo_mat' = e(att_ci_lower)
            matrix `bs_att_ci_hi_mat' = e(att_ci_upper)
            matrix `bs_att_lb_mat' = `bs_att_ci_lo_mat'
            matrix `bs_att_ub_mat' = `bs_att_ci_hi_mat'
            matrix `bs_n_by_period_mat' = e(N_by_period)

            // Bootstrap returns to the original panel after collecting
            // resamples, so explicitly persist the point-estimate ATT objects
            // needed by predict/postestimation before the main command
            // restores `_pte_orig_data'.
            preserve
            local _att_keep "`id' `time'"
            foreach _v in _pte_nt _pte_omega_0 _pte_omega_0_trim ///
                _pte_tt _pte_tt_trim _pte_tt_raw ///
                _pte_eps0_draw _pte_eps0_trim_draw ///
                _pte_tt_raw_sd _pte_tt_sd _pte_tt_trim_sd {
                capture confirm variable `_v'
                if _rc == 0 {
                    local _att_keep "`_att_keep' `_v'"
                }
            }
            quietly keep `_att_keep'
            quietly merge 1:1 `id' `time' using `_pte_internal_vars', nogenerate
            quietly save `_pte_internal_vars', replace
            restore
        }
        else {
            // Direct ATT estimation keeps the simulated counterfactual objects
            // in memory, unlike the bootstrap worker that rebuilds them each draw.
            if "`nolog'" == "" {
                if "`verbose'" != "" {
                    di as text ""
                    di as text "Step 3/4: ATT Estimation (Proposition 4.3)"
                    di as text "{hline 70}"
                }
                else {
                    display as text "  Step 3/4: ATT estimation..." _continue
                }
            }

            // Build _pte_att option string
            local _att_opts "treatment(`treatment') omegapoly(`omegapoly')"
            local _att_opts "`_att_opts' attperiods(`attperiods') nsim(`nsim') seed(`att_point_seed')"
            local _att_opts "`_att_opts' touse(`_pte_touse')"
            if `replicate_legacy_pooled_eps0' {
                local _att_opts "`_att_opts' legacypooledeps0"
            }
            if "`notrimeps'" != "" {
                local _att_opts "`_att_opts' notrimeps"
            }
            if "`nodiagnose'" != "" {
                local _att_opts "`_att_opts' nodiagnose"
            }

            if "`verbose'" == "" & "`nolog'" == "" {
                capture _pte_att, `_att_opts'
            }
            else {
                capture noisily _pte_att, `_att_opts'
            }
            local _att_rc = _rc
            if `_att_rc' != 0 {
                quietly use `_pte_orig_data', clear
                quietly xtset `id' `time' `_pte_xtset_delta_opt'
                if `_pte_has_prev_est' {
                    capture estimates restore `_pte_prev_est'
                    capture estimates drop `_pte_prev_est'
                    local _pte_has_prev_est = 0
                }
                else {
                    capture ereturn clear
                }
                _pte_error, errcode(`_att_rc') ///
                    msg("ATT estimation failed (rc = `_att_rc')")
            }

            if "`verbose'" == "" & "`nolog'" == "" {
                display as result " done"
            }

            // Direct ATT estimation returns row vectors for event-time effects.
            // Use ATT_avg scalars for overall effects and keep the matrices for
            // displays and predict.
            tempname att_se_vec_mat
            local att_overall = e(ATT_avg)
            local att_raw_overall = e(ATT_avg_raw)
            capture local att_se = e(att_se_overall)
            if _rc != 0 {
                matrix `att_se_vec_mat' = e(att_se)
                local att_se = `att_se_vec_mat'[1, colsof(`att_se_vec_mat')]
            }
            local att_N = e(att_N)
            capture local att_cf_missing_unexpected = e(N_cf_missing_unexpected)
            if _rc != 0 local att_cf_missing_unexpected = .
            capture local att_cf_trim_missing_unexpected = e(N_cf_trim_missing_unexpected)
            if _rc != 0 local att_cf_trim_missing_unexpected = .

            local att_trim_overall = e(ATT_avg_trim)
            local att_trim_se = e(att_trim_se)

            // Save period-specific effects before later code overwrites e().
            forvalues s = 0/`attperiods' {
                capture local att_`s' = e(att_`s')
                if _rc != 0 local att_`s' = .
                capture local att_trim_`s' = e(att_trim_`s')
                if _rc != 0 local att_trim_`s' = .
                capture local att_raw_`s' = e(att_raw_`s')
                if _rc != 0 local att_raw_`s' = .
            }

            // Keep the full ATT matrices for downstream graphs and exports.
            tempname att_table_mat att_trim_table_mat att_raw_table_mat
            matrix `att_table_mat' = e(att_table)
            matrix `att_trim_table_mat' = e(att_trim_table)
            capture matrix `att_raw_table_mat' = e(att_raw_table)

            // _pte_display expects one row with event times followed by ATT_avg.
            tempname att_vec_mat att_trim_vec_mat att_raw_vec_mat att_sd_vec_mat att_sd_trim_vec_mat att_sd_raw_vec_mat n_by_period_mat
            matrix `att_vec_mat' = e(att)
            matrix `att_trim_vec_mat' = e(att_trim)
            matrix `att_raw_vec_mat' = e(att_raw)
            capture matrix `att_sd_vec_mat' = e(att_sd)
            capture matrix `att_sd_trim_vec_mat' = e(att_sd_trim)
            capture matrix `att_sd_raw_vec_mat' = e(att_sd_raw)
            capture matrix `att_se_vec_mat' = e(att_se)
            capture matrix `n_by_period_mat' = e(N_by_period)

            // Downstream postestimation commands expect the event-time support.
            tempname attperiods_mat
            matrix `attperiods_mat' = e(attperiods)

            // Save ATT objects for predict after the main command exits.
            preserve
            local _att_keep "`id' `time'"
            foreach _v in _pte_nt _pte_omega_0 _pte_omega_0_trim ///
                _pte_tt _pte_tt_trim _pte_tt_raw ///
                _pte_eps0_draw _pte_eps0_trim_draw ///
                _pte_tt_raw_sd _pte_tt_sd _pte_tt_trim_sd {
                capture confirm variable `_v'
                if _rc == 0 {
                    local _att_keep "`_att_keep' `_v'"
                }
            }
            quietly keep `_att_keep'
            quietly merge 1:1 `id' `time' using `_pte_internal_vars', nogenerate
            quietly save `_pte_internal_vars', replace
            restore
        }
    }


    // Optional normalization is applied only on the treatdependent path.
    local normalize_succeeded = 0
    local normalize_method_ret ""
    local omega_norm_ret ""
    local att_norm_computed_flag_ret ""
    local att_norm_computed_ret .
    local att_norm_horizon_ret .
    if "`treatdependent'" != "" & "`normalize'" != "" & "`normalize'" != "none" {
        if "`nolog'" == "" {
            di as text ""
            di as text "Step: Productivity Normalization"
            di as text "{hline 70}"
        }
        
        local _norm_opts "method(`normalize')"
        if "`attnorm'" != "" local _norm_opts "`_norm_opts' attnorm"
        if "`nolog'" != "" local _norm_opts "`_norm_opts' quietly"
        
        capture noisily _pte_normalize, `_norm_opts'
        local _norm_rc = _rc
        if `_norm_rc' != 0 {
            quietly use `_pte_orig_data', clear
            quietly xtset `id' `time' `_pte_xtset_delta_opt'
            if `_pte_has_prev_est' {
                capture estimates restore `_pte_prev_est'
                capture estimates drop `_pte_prev_est'
                local _pte_has_prev_est = 0
            }
            else {
                capture ereturn clear
            }
            _pte_error, errcode(`_norm_rc') ///
                msg("Productivity normalization failed (rc = `_norm_rc')") ///
                suggestion("Inspect the normalization error shown above and rerun after fixing the requested treatdependent normalization inputs")
        }
        local normalize_method_ret "`e(normalize_method)'"
        local omega_norm_ret "`e(omega_norm)'"
        local att_norm_computed_flag_ret "`e(att_norm_computed_flag)'"
        capture local att_norm_computed_ret = e(att_norm_computed)
        capture local att_norm_horizon_ret = e(attperiods_max)
        if _rc == 0 & !missing(`att_norm_computed_ret') & `att_norm_computed_ret' == 1 ///
            & !missing(`att_norm_horizon_ret') {
            forvalues s = 0/`att_norm_horizon_ret' {
                capture local att_norm_`s'_ret = e(att_norm_`s')
            }
        }
        local normalize_succeeded = 1
    }

    // Restore the untouched panel and merge back only the latent objects that
    // predict/postestimation needs after estimation-side data expansion.
    quietly use `_pte_orig_data', clear
    quietly xtset `id' `time' `_pte_xtset_delta_opt'

    // Merge back the internal variables published under stable _pte_* names.
    // If the caller's original data already had same-named _pte_* columns,
    // the estimation-time state must win; otherwise e(beta_controls) and the
    // live data drift onto different semantic objects after restore.
    foreach _pte_shadow of local _pte_merge_shadow_vars {
        capture confirm variable `_pte_shadow', exact
        if _rc == 0 {
            capture drop `_pte_shadow'
        }
    }
    quietly merge 1:1 `id' `time' using `_pte_internal_vars', nogenerate

    // Live reruns of the productivity-recovery/ATT workers still consume the canonical state
    // object names phi and omega. The public command keeps _pte_phi/_pte_omega
    // for predict/postestimation, but dropping the public aliases breaks the
    // main-command -> worker bridge even though the underlying state survives.
    capture confirm variable _pte_phi, exact
    if _rc == 0 {
        capture confirm variable phi, exact
        if _rc == 0 {
            capture drop phi
        }
        quietly gen double phi = _pte_phi
        local _pte_phi_label : variable label _pte_phi
        if `"`_pte_phi_label'"' == "" {
            local _pte_phi_label "First-stage fitted value (controls subtracted)"
        }
        label variable phi `"`_pte_phi_label'"'
    }
    capture confirm variable _pte_omega, exact
    if _rc == 0 {
        capture confirm variable omega, exact
        if _rc == 0 {
            capture drop omega
        }
        quietly gen double omega = _pte_omega
        local _pte_omega_label : variable label _pte_omega
        if `"`_pte_omega_label'"' == "" {
            local _pte_omega_label "Implied productivity (omega)"
        }
        label variable omega `"`_pte_omega_label'"'
    }

    // Rebuild the exposed estimation sample from the actual stage-1 GMM sample.
    // Public e(b) stores production-function coefficients, so e(sample)/e(N)
    // must follow the observations that identified those coefficients rather
    // than the broader omega-recovery workflow support.
    tempvar _pte_main_esample
    quietly gen byte `_pte_main_esample' = (`_pte_pf_esample_live' == 1)
    quietly count if `_pte_main_esample'
    local pte_N = r(N)

    // Delay formatted output until the consolidated e() bundle is complete.
    // _pte_display reads only from e(), so all scalars and matrices must be
    // posted first.
    ereturn clear

    // The public point path has coefficient estimates but no published
    // analytical covariance matrix. Post only e(b) to avoid a fake e(V).
    if "`pfunc'" == "translog" {
        tempname __b
        matrix `__b' = (`pf_beta_l', `pf_beta_k', `pf_beta_ll', `pf_beta_kk', `pf_beta_lk')
        // e(b) contains only GMM-estimated production-function coefficients.
        // Control coefficients are partialled out before the GMM step.
        local _bnames "`free' `state' l2 k2 l1k1"
        matrix colnames `__b' = `_bnames'
        matrix rownames `__b' = y1
        matrix coleq `__b' = ""
        local _bdim = colsof(`__b')
        ereturn post `__b', esample(`_pte_main_esample')
    }
    else {
        tempname __b
        matrix `__b' = (`pf_beta_l', `pf_beta_k')
        // Cobb-Douglas stores only the labor and capital coefficients.
        // Control coefficients are partialled out before the GMM step.
        local _bnames "`free' `state'"
        matrix colnames `__b' = `_bnames'
        matrix rownames `__b' = y1
        matrix coleq `__b' = ""
        local _bdim = colsof(`__b')
        ereturn post `__b', esample(`_pte_main_esample')
    }

    // Production-function parameters
    ereturn scalar beta_l = `pf_beta_l'
    ereturn scalar beta_k = `pf_beta_k'
    if "`pfunc'" == "translog" {
        ereturn scalar beta_ll = `pf_beta_ll'
        ereturn scalar beta_kk = `pf_beta_kk'
        ereturn scalar beta_lk = `pf_beta_lk'
    }
    if `pf_has_beta_controls' {
        ereturn matrix beta_controls = `pf_beta_controls_mat'
        if `pf_n_beta_controls' == 1 {
            // Preserve the benchmark single-control scalar contract.
            ereturn scalar beta_t = `pf_beta_t'
        }
    }
    // Public sample size must match the posted e(sample) (omega-recovered sample).
    ereturn scalar N = `pte_N'
    capture ereturn scalar N_gmm = `pf_N_gmm'
    capture ereturn scalar fval = `pf_fval'
    capture ereturn scalar converged = `pf_converged'
    capture ereturn scalar iterations = `pf_iterations'

    // Evolution-law parameters
    ereturn scalar rho0 = `om_rho0'
    ereturn scalar rho1 = `om_rho1'
    if `omegapoly' >= 2 ereturn scalar rho2 = `om_rho2'
    if `omegapoly' >= 3 ereturn scalar rho3 = `om_rho3'
    if `omegapoly' >= 4 ereturn scalar rho4 = `om_rho4'
    if `om_has_gamma1' ereturn scalar gamma1 = `om_gamma1'
    if `om_has_gamma2' ereturn scalar gamma2 = `om_gamma2'
    if `om_has_gamma3' ereturn scalar gamma3 = `om_gamma3'
    if `om_has_gamma4' ereturn scalar gamma4 = `om_gamma4'
    if `om_has_delta' ereturn scalar delta = `om_delta'
    ereturn scalar sigma_eps = `om_sigma_eps'
    ereturn scalar sigma_eps_trim = `om_sigma_eps_trim'
    ereturn scalar trimeps = `om_trimeps'
    ereturn scalar N_omega = `om_N_omega'
    ereturn scalar N_evo = `om_N_evo'
    ereturn scalar N_eps0 = `om_N_eps0'
    ereturn scalar N_eps0_trim = `om_N_eps0_trim'
    ereturn scalar eps0_p1 = `om_eps0_p1'
    ereturn scalar eps0_p99 = `om_eps0_p99'
    ereturn scalar N_lag_untreated = `om_N_lag_untreated'
    ereturn scalar N_lag_treated = `om_N_lag_treated'
    ereturn scalar lag_treated_supported = `om_lag_treated_supported'
    ereturn scalar r2_evo = `om_r2_evo'
    ereturn scalar rmse_evo = `om_rmse_evo'

    // Evolution-law matrices
    ereturn matrix rho_0 = `rho_0_mat'
    if `om_has_rho_1' {
        ereturn matrix rho_1 = `rho_1_mat'
    }

    // ATT and inference objects
    if `do_att' {
        ereturn scalar ATT_avg = `att_overall'
        capture ereturn scalar ATT_avg_trim = `att_trim_overall'
        capture ereturn scalar ATT_avg_raw = `att_raw_overall'
        capture ereturn scalar N_cf_missing_unexpected = `att_cf_missing_unexpected'
        capture ereturn scalar N_cf_trim_missing_unexpected = `att_cf_trim_missing_unexpected'

        if `do_bootstrap' {
            ereturn scalar bs_se = `att_se'
            ereturn scalar ci_lo = `att_ci_lo'
            ereturn scalar ci_hi = `att_ci_hi'
            capture ereturn scalar bs_se_raw = `att_raw_se'
            capture ereturn scalar ci_lo_raw = `att_raw_ci_lo'
            capture ereturn scalar ci_hi_raw = `att_raw_ci_hi'
            capture ereturn scalar bs_se_trim = `att_trim_se'
            capture ereturn scalar ci_lo_trim = `att_trim_ci_lo'
            capture ereturn scalar ci_hi_trim = `att_trim_ci_hi'
            ereturn scalar n_success = `bs_n_success'
            ereturn scalar n_fail = `bs_n_fail'
        }
        else {
            ereturn scalar att_se_overall = `att_se'
            ereturn scalar att_N = `att_N'
            capture ereturn scalar att_trim_se = `att_trim_se'
        }
        // Period-specific ATT
        forvalues s = 0/`attperiods' {
            if !missing(`att_`s'') {
                ereturn scalar att_`s' = `att_`s''
            }
            if `do_bootstrap' {
                capture ereturn scalar bs_se_`s' = `att_se_`s''
                capture ereturn scalar ci_lo_`s' = `att_ci_lo_`s''
                capture ereturn scalar ci_hi_`s' = `att_ci_hi_`s''
                capture ereturn scalar bs_se_raw_`s' = `att_raw_se_`s''
                capture ereturn scalar ci_lo_raw_`s' = `att_raw_ci_lo_`s''
                capture ereturn scalar ci_hi_raw_`s' = `att_raw_ci_hi_`s''
            }
            if !missing(`att_trim_`s'') {
                ereturn scalar att_trim_`s' = `att_trim_`s''
            }
            if !missing(`att_raw_`s'') {
                ereturn scalar att_raw_`s' = `att_raw_`s''
            }
        }

        // Bootstrap matrices
        if `do_bootstrap' {
            ereturn matrix bs_raw = `bs_raw_mat'
            ereturn matrix bs_betas = `bs_betas_mat'
            ereturn matrix result_table_raw = `rtab_raw_mat'
            if `do_trim' {
                ereturn matrix bs_trim = `bs_trim_mat'
                ereturn matrix result_table_trim = `rtab_trim_mat'
            }
            // Publish dynamic standard errors and confidence bounds.
            ereturn matrix att_se = `bs_att_se_mat'
            ereturn matrix att_ci_lower = `bs_att_ci_lo_mat'
            ereturn matrix att_ci_upper = `bs_att_ci_hi_mat'
            
            // Keep the worker's exact realized support instead of rebuilding
            // a dense 0..L grid from scalar aliases.
            ereturn matrix att = `bs_att_mat'
            ereturn matrix att_trim = `bs_att_trim_mat'
            ereturn matrix att_raw = `bs_att_raw_mat'
            ereturn matrix att_lb = `bs_att_lb_mat'
            ereturn matrix att_ub = `bs_att_ub_mat'
            ereturn matrix N_by_period = `bs_n_by_period_mat'
            ereturn matrix attperiods = `bs_attperiods_mat'
        }
        else {
            ereturn matrix att_table = `att_table_mat'
            ereturn matrix att_trim_table = `att_trim_table_mat'
            capture ereturn matrix att_raw_table = `att_raw_table_mat'
            // Keep the direct-estimation row-vector layout for displays and
            // degraded nonabsorbing return mapping.
            ereturn matrix att = `att_vec_mat'
            ereturn matrix att_trim = `att_trim_vec_mat'
            ereturn matrix att_raw = `att_raw_vec_mat'
            capture ereturn matrix att_sd = `att_sd_vec_mat'
            capture ereturn matrix att_sd_trim = `att_sd_trim_vec_mat'
            capture ereturn matrix att_sd_raw = `att_sd_raw_vec_mat'
            capture ereturn matrix att_se = `att_se_vec_mat'
            capture ereturn matrix N_by_period = `n_by_period_mat'
            // Publish the event-time support matrix for postestimation helpers.
            ereturn matrix attperiods = `attperiods_mat'
        }
    }

    // Configuration metadata
    ereturn scalar omegapoly = `omegapoly'
    ereturn scalar attperiods_max = `attperiods'
    ereturn scalar nsim = `nsim'
    ereturn scalar eps0window = `om_eps0window'
    ereturn scalar legacy_pooled_eps0 = `om_legacy_pooled_eps0'
    if `do_att' | `bootstrap' > 0 {
        ereturn scalar seed = `seed'
        ereturn scalar seed_actual = `seed'
        ereturn scalar seed_user = `seed_user'
        ereturn local seed_source "`seed_source'"
        ereturn local seed_route "serial"
    }
    ereturn scalar bootstrap = `bootstrap'
    if `bootstrap' > 0 {
        ereturn scalar point_seed = `att_bootstrap_seed'
        ereturn scalar inner_seed = `att_bootstrap_seed'
        ereturn scalar seed_inner = `att_bootstrap_seed'
        ereturn scalar seed_outer = `seed'
        if `"`bs_inner_seed_source'"' != "" {
            ereturn local inner_seed_source "`bs_inner_seed_source'"
        }
        if `"`bs_seed_outer_strategy'"' != "" {
            ereturn local seed_outer_strategy "`bs_seed_outer_strategy'"
        }
    }
    else if `do_att' {
        ereturn scalar point_seed = `att_point_seed'
    }
    ereturn scalar level = `level'
    ereturn scalar poly = `poly'

    // Panel summary statistics kept for prodest-compatible displays
    ereturn scalar N_g = `nGroups'
    ereturn scalar N_clust = `nGroups'
    ereturn scalar df_r = `pf_N' - `_bdim'
    ereturn scalar tmin = `minGroup'
    ereturn scalar tmean = `meanGroup'
    ereturn scalar tmax = `maxGroup'

    // Treatment-support counts
    ereturn scalar N_treated = `N_treated'
    ereturn scalar N_control = `N_control'
    ereturn scalar N_trans = `N_trans'

    // Local metadata used by postestimation commands
    local pte_treatsig ""
    local pte_comparesig ""
    capture quietly _pte_treatment_signature, ///
        panelvar(`id') timevar(`time') treatment(`treatment')
    if _rc == 0 {
        local pte_treatsig `"`r(signature)'"'
    }
    local _pte_compare_controls_opt ""
    if `"`control'"' != "" {
        local _pte_compare_controls_opt `"controls(`control')"'
    }
    capture quietly _pte_compare_signature, ///
        panelvar(`id') timevar(`time') treatment(`treatment') ///
        depvar(`depvar') free(`free') state(`state') proxy(`proxy') ///
        `_pte_compare_controls_opt'
    if _rc == 0 {
        local pte_comparesig `"`r(signature)'"'
    }

    ereturn local depvar "`depvar'"
    ereturn local free "`free'"
    ereturn local state "`state'"
    ereturn local proxy "`proxy'"
    ereturn local controls "`control'"
    ereturn local treatment "`treatment'"
    ereturn local treatsig `"`pte_treatsig'"'
    ereturn local comparesig `"`pte_comparesig'"'
    ereturn local id "`id'"
    ereturn local time "`time'"
    ereturn local pfunc "`pfunc'"
    ereturn local prodfunc "`pfunc'"
    if "`pf_z_moment_layout'" != "" {
        ereturn local z_moment_layout "`pf_z_moment_layout'"
    }
    if "`pf_do_pooled_z'" != "" {
        ereturn scalar do_pooled_z = `pf_do_pooled_z'
    }
    ereturn local PFtype "`PFtype'"
    ereturn local method "acf"
    ereturn local model "valueadded"
    ereturn local correction "clk"
    ereturn local panelvar "`id'"
    ereturn local idvar "`id'"
    ereturn local timevar "`time'"
    if "`xtdelta'" != "" {
        ereturn scalar xtdelta = `xtdelta'
    }
    if "`notrimeps'" != "" {
        ereturn local notrimeps "notrimeps"
    }
    if "`replicate'" != "" {
        ereturn local replicate "`replicate'"
    }
    ereturn local predict "pte_p"
    ereturn local cmd "pte"
    ereturn local title "Productivity Treatment Effects"
    ereturn local version "1.0.0"
    ereturn local cmdline "pte `0'"

    // predict checks whether ATT objects were intentionally skipped.
    if "`noatt'" != "" {
        ereturn scalar noatt = 1
    }
    else {
        ereturn scalar noatt = 0
    }

    // Preserve extension flags exactly as requested by the caller.
    if "`treatdependent'" != "" {
        ereturn scalar treatdependent = 1
    }
    else {
        ereturn scalar treatdependent = 0
    }
    if "`treatdependent'" != "" & "`normalize'" != "" & "`normalize'" != "none" ///
        & `normalize_succeeded' == 1 {
        ereturn local normalize "`normalize'"
        if `"`normalize_method_ret'"' != "" {
            ereturn local normalize_method `"`normalize_method_ret'"'
        }
        if `"`omega_norm_ret'"' != "" {
            ereturn local omega_norm `"`omega_norm_ret'"'
        }
        if `"`att_norm_computed_flag_ret'"' != "" {
            ereturn local att_norm_computed_flag `"`att_norm_computed_flag_ret'"'
        }
        if !missing(`att_norm_computed_ret') {
            ereturn scalar att_norm_computed = `att_norm_computed_ret'
        }
        if !missing(`att_norm_computed_ret') & `att_norm_computed_ret' == 1 ///
            & !missing(`att_norm_horizon_ret') {
            forvalues s = 0/`att_norm_horizon_ret' {
                capture confirm number `att_norm_`s'_ret'
                if _rc == 0 {
                    ereturn scalar att_norm_`s' = `att_norm_`s'_ret'
                }
            }
        }
    }

    // Re-apply xtset because preserve/use can clear panel metadata even when
    // the original sort order and variables have been restored.
    quietly xtset `id' `time' `_pte_xtset_delta_opt'

    // Degraded nonabsorbing mode still exposes the switch-in/switch-out return
    // shape expected by downstream nonabsorbing tools.
    if `_pte_is_degraded' == 1 & `do_att' {
        capture _pte_set_degraded_returns, ///
            attperiods(`attperiods') nentry(`_pte_na_N_entry')
        if _rc != 0 {
            if `_pte_has_prev_est' {
                capture estimates restore `_pte_prev_est'
                capture estimates drop `_pte_prev_est'
            }
            else {
                capture ereturn clear
            }
            di as error "Error mapping return values to non-absorbing interface"
            di as error "Please report this bug to package maintainer"
            exit 111
        }
    }

    if `_pte_has_prev_est' {
        capture estimates drop `_pte_prev_est'
    }

    // Final results summary should not inherit nolog; that option only
    // suppresses estimation-progress chatter, not the posted replay/display.
    if "`verbose'" == "" & "`nolog'" == "" {
        display as text "  Step 4/4: Complete"
        display as text "{hline 70}"
        display ""
    }
    _pte_display, `noatt' level(`level') `verbose'

end
