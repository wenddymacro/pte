{smcl}
{* *! version 1.0.0  18mar2026}{...}
{vieweralsosee "pte" "help pte"}{...}
{vieweralsosee "pte_diagnose" "help pte_diagnose"}{...}
{vieweralsosee "xtset" "help xtset"}{...}
{viewerjumpto "Syntax" "pte_setup##syntax"}{...}
{viewerjumpto "Description" "pte_setup##description"}{...}
{viewerjumpto "Options" "pte_setup##options"}{...}
{viewerjumpto "Remarks" "pte_setup##remarks"}{...}
{viewerjumpto "Examples" "pte_setup##examples"}{...}
{viewerjumpto "Stored results" "pte_setup##results"}{...}
{viewerjumpto "References" "pte_setup##references"}{...}
{cmd:help pte_setup}{right:also see: {helpb pte}}
{hline}

{title:Title}

{p2colset 5 22 24 2}{...}
{p2col:{hi:pte_setup} {hline 1} Prepare panel treatment metadata and setup diagnostics for PTE}{p_end}
{p2colreset}{...}

{marker syntax}{...}
{title:Syntax}

{p 8 17 2}
{cmd:pte_setup}
{cmd:,}
{cmdab:treat:ment(}{it:name}{cmd:)}
[{it:options}]

{marker options}{...}
{title:Options}

{synoptset 30 tabbed}{...}
{synopthdr}
{synoptline}
{syntab:Core}
{synopt:{opt treat:ment(name)}}binary numeric treatment indicator {it:D_it}; the
variable name must match an existing column exactly, string variables are
rejected with {cmd:rc=198}, and all-missing treatment columns are rejected with
{cmd:rc=416}{p_end}
{synopt:{opt firmid(varname)}}panel id variable; default is current {cmd:xtset}
id; if the dataset is not already {cmd:xtset}, supply {cmd:firmid()} together
with {cmd:timevar()}{p_end}
{synopt:{opt timevar(varname)}}time variable; default is current {cmd:xtset}
time variable; if the dataset is not already {cmd:xtset}, supply {cmd:timevar()}
together with {cmd:firmid()}{p_end}
{synopt:{opt check}}audit mode; skip creation of {cmd:_pte_*} helper variables
in a non-mutating check path{p_end}
{synopt:{opt absor:bing}}strict absorbing-treatment check; errors out if 1->0
transitions are found{p_end}
{synopt:{opt report}}print an additional setup summary report{p_end}
{synopt:{opt minthreshold(#)}}nonnegative minimum threshold used by summary
identification checks; default is {cmd:100}{p_end}

{syntab:Variable generation}
{synopt:{opt generate(string)}}currently only accepts the canonical {cmd:_pte_}
prefix; {cmd:generate(_pte)} is accepted as a compatibility alias and normalized
to the canonical {cmd:_pte_} prefix, while other prefixes are rejected{p_end}
{synopt:{opt replace}}allow overwriting pre-existing generated {cmd:_pte_*}
variables; ignored with {opt check}{p_end}

{syntab:Input-role validation (optional)}
{synopt:{opt output(varname)}}candidate output variable to validate; the name
must match an existing numeric variable exactly, and string variables are
rejected with {cmd:rc=109}{p_end}
{synopt:{opt free(varlist)}}candidate free inputs to validate; each name must
match an existing numeric variable exactly, and string variables are rejected
with {cmd:rc=109}{p_end}
{synopt:{opt state(varlist)}}candidate state inputs to validate; each name must
match an existing numeric variable exactly, and string variables are rejected
with {cmd:rc=109}{p_end}
{synopt:{opt proxy(varlist)}}candidate proxy inputs to validate; each name must
match an existing numeric variable exactly, and string variables are rejected
with {cmd:rc=109}{p_end}
{synoptline}

{marker description}{...}
{title:Description}

{pstd}
{cmd:pte_setup} is an {cmd:rclass} setup utility for public PTE workflows.
It validates treatment-path structure, optionally creates canonical helper
variables, and returns setup diagnostics used before running {cmd:pte}.

{pstd}
When generation is enabled (default), the command creates or refreshes:
{cmd:_pte_D}, {cmd:_pte_treat_year}, {cmd:_pte_first_treat_year},
{cmd:_pte_nt}, {cmd:_pte_mid}, {cmd:_pte_treat}, and {cmd:_pte_cohort}.

{pstd}
Transition periods follow the package rule:
{it:mid = 1} iff {it:D_it != D_{i,t-1}}, and the first observed period in
each panel unit is set to {it:mid = 0} because lagged treatment is missing.

{marker remarks}{...}
{title:Remarks}

{dlgtab:Prerequisites}

{pstd}
{cmd:pte_setup} requires panel data context. If {cmd:firmid()} and
{cmd:timevar()} are omitted, the command reads the current {cmd:xtset}
declaration.

{pstd}
If the dataset is not already {cmd:xtset}, {cmd:firmid()} and
{cmd:timevar()} must be supplied together. Providing only one of the two
options leaves the panel-time mapping underidentified and the command exits
with {cmd:rc=459}.

{pstd}
A panel-only declaration such as {cmd:xtset firmid} is also incomplete for
{cmd:pte_setup}. If the current {cmd:xtset} metadata do not include a time
variable, either supply {cmd:timevar()} to complete the existing panel
declaration, supply {cmd:firmid()} together with {cmd:timevar()}, or re-run
{cmd:xtset} with both axes before calling {cmd:pte_setup}.

{pstd}
The treatment variable must contain at least one nonmissing {cmd:0}/{cmd:1}
observation. A treatment column that is entirely missing is rejected at the
public layer with {cmd:rc=416}, rather than being misclassified as a
non-binary treatment variable.

{pstd}
The optional input-role arguments {opt output()}, {opt free()},
{opt state()}, and {opt proxy()} are also checked against the caller's
literal variable names and numeric types. Unique abbreviation fallback is
rejected at the public layer, so {cmd:lny} will not silently bind to
{cmd:lny_shadow}, and string input-role variables are rejected with
{cmd:rc=109} before the validation helper reports missing/nonpositive cells.

{pstd}
{opt generate()} is currently a namespace-compatibility guard rather than a
custom-prefix facility. The command always uses the canonical {cmd:_pte_}
helper namespace and returns {cmd:r(generate) = "_pte_"}. If you specify
{cmd:generate(_pte)}, that alias is accepted for compatibility and normalized
to the canonical {cmd:_pte_} prefix.

{pstd}
When {cmd:pte_setup} temporarily switches panel declarations internally,
it restores the caller's original {cmd:xtset} contract, including
{cmd:delta()}.

{pstd}
When helper generation is enabled, {cmd:pte_setup} also stores the resolved
setup panel/time variables, resolved {cmd:delta()}, and treatment variable in
dataset characteristics so post-setup diagnostics and postestimation consumers
can continue to use the same axes, lag law, and treatment law even after the
caller's original {cmd:xtset} declaration has been restored.

{dlgtab:check mode}

{pstd}
With {opt check}, {cmd:pte_setup} still validates treatment structure and
returns summary diagnostics, but it does {bf:not} create helper variables.
This is useful for non-mutating audits of candidate datasets. replace is ignored
in check mode, so existing {cmd:_pte_*} variables are left unchanged and missing
helper variables are not created.

{pstd}
If the audited panel/time/treatment law no longer matches the last stored
setup contract, {opt check} invalidates the stale
{cmd:_dta[_pte_setup_*]} characteristics and clears stale live {cmd:pte}
estimates instead of publishing a new setup contract. Re-run
{cmd:pte_setup} without {opt check} before using post-setup consumers on the
audited data.

When the active {cmd:pte} result uses dot-sentinel metadata such as
{cmd:e(idvar)="."}, {cmd:e(timevar)="."}, or {cmd:e(treatment)="."},
{cmd:pte_setup} treats those aliases as missing and falls back to the legacy
{cmd:e(id)} / {cmd:e(time)} fields plus matching {cmd:e(treatsig)} and
{cmd:e(xtdelta)} before deciding whether the live result is stale.

{pstd}
Without {opt check}, a successful {cmd:pte_setup} publishes a new
dataset-scoped treatment-law signature. Any active live {cmd:pte} result that
does not publish a matching {cmd:e(treatsig)} is cleared immediately rather
than being left for downstream {cmd:predict}/{cmd:pte_graph}/{cmd:pte_diagnose}
consumers to reject later as uncertified state.

{pstd}
This publication step is fail-closed. If {cmd:pte_setup} cannot compute the
treatment-law signature after validating the panel/time axis and treatment
path, the command exits before writing any new {cmd:_dta[_pte_setup_*]}
characteristics. It never leaves a partial setup contract behind, and a failed
non-{opt check} rerun restores the last certified {cmd:_pte_*} helper bundle
instead of leaking helpers from the uncertified treatment law.

{pstd}
The stored setup contract is atomic: {cmd:_dta[_pte_setup_panelvar]},
{cmd:_dta[_pte_setup_timevar]}, {cmd:_dta[_pte_setup_treatment]},
{cmd:_dta[_pte_setup_treatsig]}, and {cmd:_dta[_pte_setup_xtdelta]} must
either all be present or all be absent. A partial bundle is treated as stale
provenance and downstream consumers fail closed.

{pstd}
The public {opt check} contract is also row-order preserving: internal
{cmd:xtset}, {cmd:tsset}, and {cmd:bysort} work needed for the audit do not
change the caller's current observation order.

{pstd}
In {opt check} mode, {opt report} still prints a lightweight non-mutating
setup summary report headed by {cmd:PTE Data Setup Summary}. However,
because helper variables are not created in the caller's dataset,
{cmd:r(avg_pre)} and {cmd:r(avg_post)} are still returned missing, while
{cmd:r(assumption_pass)} continues to use the simple stable-support
threshold rule based on {cmd:r(N_stable_0)} and {cmd:r(N_stable_1)}.

{dlgtab:Absorbing vs non-absorbing}

{pstd}
Without {opt absorbing}, non-absorbing treatment paths are allowed and are
reported through {cmd:r(trt_type)}. With {opt absorbing}, the command exits
with an error when it detects any 1->0 transition.

{dlgtab:minthreshold()}

{pstd}
{opt minthreshold()} accepts nonnegative integers only and affects only the
identification summary flags reported by
the setup summary branch. It does not redefine treatment transitions or
the helper-variable formulas.

{marker examples}{...}
{title:Examples}

{pstd}{bf:Run setup using current xtset panel variables}{p_end}
{phang2}{cmd:. pte_example, clear}{p_end}
{phang2}{cmd:. xtset firm year}{p_end}
{phang2}{cmd:. pte_setup, treatment(D)}{p_end}

{pstd}{bf:Non-mutating treatment audit}{p_end}
{phang2}{cmd:. pte_example, clear}{p_end}
{phang2}{cmd:. xtset firm year}{p_end}
{phang2}{cmd:. pte_setup, treatment(D) check report}{p_end}

{pstd}{bf:Strict absorbing-treatment check}{p_end}
{phang2}{cmd:. pte_example, clear}{p_end}
{phang2}{cmd:. xtset firm year}{p_end}
{phang2}{cmd:. pte_setup, treatment(D) absorbing}{p_end}

{pstd}{bf:Validate candidate production-function inputs during setup}{p_end}
{phang2}{cmd:. pte_example, clear}{p_end}
{phang2}{cmd:. xtset firm year}{p_end}
{phang2}{cmd:. pte_setup, treatment(D) output(lny) free(lnl) state(lnk) proxy(lnm)}{p_end}

{marker results}{...}
{title:Stored results}

{pstd}
{cmd:pte_setup} stores the following in {cmd:r()}:

{synoptset 30 tabbed}{...}
{p2col 5 30 34 2: Scalars}{p_end}
{synopt:{cmd:r(N_obs)}}total observations checked{p_end}
{synopt:{cmd:r(N_treated_obs)}}treated observations ({cmd:D=1}){p_end}
{synopt:{cmd:r(N_untreated_obs)}}untreated observations ({cmd:D=0}){p_end}
{synopt:{cmd:r(N_missing)}}missing-treatment observations{p_end}
{synopt:{cmd:r(pct_treated)}}treated share among non-missing observations
(percent){p_end}
{synopt:{cmd:r(N_treated_firms)}}number of ever-treated panel units{p_end}
{synopt:{cmd:r(N_control_firms)}}number of never-treated panel units{p_end}
{synopt:{cmd:r(N_entry_events)}}number of 0->1 transitions{p_end}
{synopt:{cmd:r(N_exit_events)}}number of 1->0 transitions{p_end}
{synopt:{cmd:r(N_stable_0)}}stable untreated observations
({cmd:D_t=L.D_t=0}){p_end}
{synopt:{cmd:r(N_stable_1)}}stable treated observations
({cmd:D_t=L.D_t=1}){p_end}
{synopt:{cmd:r(N_trans)}}transition observations ({cmd:mid=1}){p_end}
{synopt:{cmd:r(n_first_d1)}}firms with {cmd:D=1} at the first observed
period{p_end}
{synopt:{cmd:r(pct_first_d1)}}share of first-observation {cmd:D=1} firms
(percent){p_end}
{synopt:{cmd:r(n_cohorts)}}number of observed-entry treatment cohorts in
generated metadata{p_end}
{synopt:{cmd:r(balanced)}}panel balancedness flag from setup-panel check{p_end}
{synopt:{cmd:r(regular)}}panel regularity flag from setup-panel check{p_end}
{synopt:{cmd:r(panel_n_obs)}}observation count from setup-panel check{p_end}
{synopt:{cmd:r(panel_n_groups)}}group count from setup-panel check{p_end}
{synopt:{cmd:r(input_validation_passed)}}optional input-role validation flag
(missing if not requested){p_end}
{synopt:{cmd:r(total_invalid_inputs)}}optional count of invalid input-role
cells{p_end}
{synopt:{cmd:r(total_nonpos)}}optional count of nonpositive values from
input-role checks{p_end}
{synopt:{cmd:r(total_miss)}}optional count of missing values from input-role
checks{p_end}
{synopt:{cmd:r(n_invalid_obs)}}optional count of observations with any
input-role issue{p_end}
{synopt:{cmd:r(avg_pre)}}average pre-treatment periods among treated units
(summary branch){p_end}
{synopt:{cmd:r(avg_post)}}average post-treatment periods among treated units
(summary branch){p_end}
{synopt:{cmd:r(assumption_pass)}}summary identification flag based on
{cmd:minthreshold()}{p_end}

{p2col 5 30 34 2: Macros}{p_end}
{synopt:{cmd:r(trt_type)}}detected treatment type: {cmd:absorbing} or
{cmd:non-absorbing}{p_end}
{synopt:{cmd:r(panelvar)}}resolved panel id variable{p_end}
{synopt:{cmd:r(timevar)}}resolved time variable{p_end}
{synopt:{cmd:r(treatment)}}treatment variable used by the command{p_end}
{synopt:{cmd:r(generate)}}current generation prefix contract
({cmd:_pte_}){p_end}
{synopt:{cmd:r(cmd)}}command name ({cmd:pte_setup}){p_end}

{marker references}{...}
{title:References}

{phang}
Chen, Z., Liao, M., and Schurter, K. (2026).
Identifying Treatment Effects on Productivity.
{it:Working Paper}.
{p_end}
