{smcl}
{* *! version 1.0.0  01jan2026}{...}
{* *! Postestimation tools for pte}{...}
{* *! Chen, Liao & Schurter (2026)}{...}

{vieweralsosee "[PTE] pte" "help pte"}{...}
{vieweralsosee "[R] predict" "help predict"}{...}
{vieweralsosee "[PTE] pte_graph" "help pte_graph"}{...}
{viewerjumpto "Syntax" "pte_postestimation##syntax"}{...}
{viewerjumpto "Description" "pte_postestimation##description"}{...}
{viewerjumpto "Options" "pte_postestimation##options"}{...}
{viewerjumpto "Remarks" "pte_postestimation##remarks"}{...}
{viewerjumpto "Examples" "pte_postestimation##examples"}{...}
{viewerjumpto "Stored results" "pte_postestimation##results"}{...}
{viewerjumpto "References" "pte_postestimation##references"}{...}
{viewerjumpto "Compatibility" "pte_postestimation##compatibility"}{...}
{cmd:help pte postestimation}{right:also see: {help pte:pte}}
{hline}

{marker title}{...}
{title:Title}

{p2colset 5 33 35 2}{...}
{p2col:{hi:pte postestimation} {hline 2} Postestimation tools for pte}{p_end}
{p2colreset}{...}


{marker syntax}{...}
{title:Syntax}

{p 8 16 2}
{cmd:predict}
[{it:type}]
{newvar}
{ifin}
[{cmd:,} {it:statistic}]

{p 8 16 2}
{cmd:predict}
[{cmd:,} {cmd:parameters}]

{marker statistic}{...}
{synoptset 20 tabbed}{...}
{synopthdr:statistic}
{synoptline}
{syntab:Main}
{synopt:{opt omega}}recovered productivity omega_it; the default{p_end}
{synopt:{opt phi}}first-stage fitted value Phi_it{p_end}
{synopt:{opt resid:uals}}untreated innovation support epsilon_it{sup:0}{p_end}
{synopt:{opt exp:onential}}productivity level exp(omega_it){p_end}
{synopt:{opt par:ameters}}display production function parameters{p_end}
{synopt:{opt tt}}firm-specific treatment effect TT_it{p_end}
{synopt:{opt att}}average treatment effect ATT by period{p_end}
{synoptline}
{p 4 6 2}
These statistics are available after estimation with {cmd:pte}.
{p_end}
{p 4 6 2}
Options {opt omega}, {opt phi}, {opt residuals}, {opt exponential},
{opt tt}, and {opt att} generate a new variable.
{p_end}
{p 4 6 2}
Option {opt parameters} displays results but does not create a
variable; {it:newvar} is not required.
{p_end}
{p 4 6 2}
Because {opt parameters} is a reporting action over stored {cmd:e()}
results rather than an observation-level prediction, {cmd:if} and
{cmd:in} qualifiers are not allowed.
{p_end}


{marker description}{...}
{title:Description}

{pstd}
{cmd:predict} after {cmd:pte} computes predicted values and
diagnostics from the estimated production function and treatment
effect model of Chen, Liao & Schurter (2026).

{pstd}
The default statistic is {opt omega}, which returns the recovered
total factor productivity for each firm-year observation.  Other
statistics provide the first-stage fitted value ({opt phi}),
untreated innovation support ({opt residuals}), the productivity level in
natural units ({opt exponential}), firm-specific treatment effects
({opt tt}), and period-average treatment effects ({opt att}).

{pstd}
The {opt parameters} option prints the estimated production function
coefficients to the Results window without creating a new variable.
Output differs for Cobb-Douglas and translog specifications.


{marker options}{...}
{title:Options}

{dlgtab:Main}

{phang}
{opt omega} computes the recovered productivity omega_it.  This is
the default.  Productivity is obtained by subtracting the
contribution of observed inputs from the first-stage fitted value
(see Eq.(1) and Corollary 4.1 in Chen, Liao & Schurter, 2026):

{p 12 12 2}
Cobb-Douglas: omega = Phi - beta_l * l - beta_k * k

{p 12 12 2}
Translog: omega = Phi - beta_l * l - beta_k * k - beta_ll * l^2
- beta_kk * k^2 - beta_lk * l * k

{pmore}
The variable {cmd:_pte_omega} must exist in the dataset.
After {cmd:pte_setup}, the live {cmd:pte} result must also publish a
matching {cmd:e(xtdelta)} for this setup-selected panel spacing;
otherwise {cmd:predict} stops rather than reusing stale omega state.

{phang}
{opt phi} returns the first-stage fitted value Phi_it used by the
CLK/ACF recovery step. The stored Phi_it has already removed the
contribution of any {opt control()} variables; it is the
controls-subtracted composite term that enters omega recovery
(Eq.(6) in Chen, Liao & Schurter, 2026). Phi captures the
combined effect of
observable inputs and unobserved productivity after that control
adjustment.

{pmore}
The variable {cmd:_pte_phi} must exist in the dataset.
After {cmd:pte_setup}, the live {cmd:pte} result must also publish a
matching {cmd:e(xtdelta)} so the stored phi path remains certified for
the current setup-selected panel spacing.

{phang}
{opt residuals} computes the untreated innovation support
epsilon_it{sup:0}, defined as the residual from the untreated
Markov productivity evolution law:

{p 12 12 2}
epsilon_it{sup:0} = omega_it - h_0(omega_{i,t-1})

{pmore}
where h_0() is the untreated polynomial approximation to the
conditional expectation E[omega_it{sup:0} | omega_{i,t-1}{sup:0}].
Observations in transition periods ({cmd:_pte_mid}==1, where
D_t != D_{t-1}) are set to missing, following Theorem 3.1 in the
paper. Treated post-entry observations are also set to missing
because realized productivity there already embeds treatment
effects and is outside the untreated-innovation support. If
{cmd:_pte_eps0} exists, it is used where available; otherwise,
residuals are computed from {cmd:_pte_omega} and the stored
untreated evolution parameters. On the serial path, this fallback
uses {cmd:e(rho_0)}. After grouped point estimation ({cmd:pte, by()}
or {cmd:pte, industry()} without bootstrap), if {cmd:_pte_eps0} is
absent the fallback instead uses {cmd:e(rho_by)} together with the
exact current grouping variable named in {cmd:e(by)} so each
observation is rebuilt from its own group's untreated law. On that
grouped fallback, {cmd:predict, residuals} uses the stored
estimation-time group order in {cmd:e(groups)} to map rows of
{cmd:e(rho_by)} back to the current data. This preserves valid string
group labels containing spaces and allows the current data to be a
subset of the original grouped sample without remapping the grouped
untreated-law rows.
Grouped bootstrap public results also support that grouped fallback
when the public repost retains {cmd:e(rho_by)} together with
{cmd:e(by)} and {cmd:e(groups)}.
On any fallback path, if the exact support indicator {cmd:_pte_eps0_ind}
is still present, {cmd:predict} keeps nonmissing residuals only on
{cmd:_pte_eps0_ind==1} so the stored untreated-innovation support and
any {cmd:eps0window()} restriction remain binding. {cmd:predict} also
restores the estimation panel structure from {cmd:e(idvar)} and
{cmd:e(timevar)}, with fallback to {cmd:e(id)} / {cmd:e(time)} when
the newer aliases are not present. The exact stored panel and time
variable names must still exist in the current data; prefix-abbreviation
matches are not accepted on this fallback path. {cmd:predict} also reuses
{cmd:e(xtdelta)} when
that spacing was stored. If the live result predates {cmd:e(xtdelta)}
but {cmd:pte_setup} has stored {cmd:_dta[_pte_setup_xtdelta]},
{cmd:predict, residuals} may still use that setup-backed delta on this
fallback path. If {cmd:eps0window()>0} and the current data contain neither
{cmd:_pte_eps0} nor {cmd:_pte_eps0_ind}, {cmd:predict, residuals} cannot rebuild
eps0 safely because the window-restricted untreated support is no longer
observable. Re-run pte before predict, residuals, or keep
_pte_eps0/_pte_eps0_ind in the current data.

{phang}
{opt exponential} computes exp(omega_it), the productivity level
in natural units.  This is useful when the production function is
estimated in logs and one wishes to express productivity on the
original output scale.

{pmore}
The variable {cmd:_pte_omega} must exist in the dataset.
After {cmd:pte_setup}, the live {cmd:pte} result must also publish a
matching {cmd:e(xtdelta)} so the stored omega path is certified for the
current setup-selected panel spacing.

{phang}
{opt parameters} displays the estimated production function
coefficients in the Results window.  No new variable is created
and {it:newvar} is not required. Because this is a reporting action
over stored {cmd:e()} results rather than an observation-level
prediction, {cmd:if} and {cmd:in} qualifiers are not allowed.
After {cmd:pte_setup}, this reporting path also requires live
{cmd:e(xtdelta)} to match {cmd:_dta[_pte_setup_xtdelta]}; otherwise the
stored coefficient payload is treated as stale for the current panel
spacing.

{pmore}
For Cobb-Douglas, the display includes beta_l (free input),
beta_k (state variable), and returns to scale (beta_l + beta_k).

{pmore}
For translog, the display additionally includes beta_ll, beta_kk,
beta_lk, and the symbolic elasticity formulas shown in the Results
window. The current public implementation does {bf:not} evaluate
those elasticities numerically at sample means.

{pmore}
When the serial/public result stores time-trend or other control
coefficients in {cmd:e(beta_controls)}, {opt parameters} also prints
those control coefficients. The benchmark single-control path is
displayed as {cmd:beta_t}.

{pmore}
After {cmd:pte, by()} or {cmd:pte, industry()}, {opt parameters} is
available for grouped point estimation: it prints the grouped
coefficient matrix {cmd:e(b_by)} instead of a single pooled
{cmd:e(beta_*)} bundle. After grouped bootstrap results, it remains
unavailable because the public result stores coefficient draws in
{cmd:e(beta_boot_g#)} and grouped coefficient-summary SE vectors in
{cmd:e(beta_se_g#)} rather than one public point-estimate matrix. If
any of those grouped bootstrap coefficient payloads remain active,
{cmd:predict, parameters} exits with {cmd:rc=198} instead of falling
back to serial {cmd:e(beta_*)} scalars or a stale grouped
{cmd:e(b_by)} surface. On grouped results, a single explicit
{cmd:control()} variable keeps the legacy {cmd:beta_t} slot, while
multiple explicit controls append their exact variable names to
{cmd:e(b_by)}, {cmd:e(beta_boot_g#)}, and {cmd:e(beta_se_g#)}.

{phang}
{opt tt} returns the firm-specific treatment effect TT_it,
computed as the difference between observed productivity and the
average simulated counterfactual productivity under no treatment
(Proposition 4.3):

{p 12 12 2}
TT_it = omega_it - (1/M) * SUM_m omega0_sim_it(m)

{pmore}
Only treated firms (D==1) with event time nt >= 0 have nonmissing
values.  The ATT estimation stage must have been completed; if
{cmd:pte} was run with the {opt noatt} option, this statistic is
not available.

{pmore}
The variables {cmd:_pte_tt}, {cmd:_pte_treat}, and {cmd:_pte_nt}
must exist in the dataset.
If the stored support in {cmd:e(attperiods)} becomes fractional,
duplicated, unsorted, or otherwise non-integer, {cmd:predict, tt}
exits with {cmd:rc=198} rather than publishing a partially mapped TT
surface. The same fail-close law applies when a listed supported event
time has zero nonmissing treated {cmd:_pte_tt} observations: an empty
supported TT period is treated as damaged state rather than replayed as a
partially blank prediction path.
After {cmd:pte_setup}, the live {cmd:pte} result must also publish a
matching {cmd:e(xtdelta)}; otherwise the stored TT path is treated as
stale for the current setup-selected panel spacing.

{phang}
{opt att} fills the new variable with the period-average treatment
effect ATT for each event-time period (Eq.(10) in Chen, Liao &
Schurter, 2026). For treated observations with event times listed
in the stored support matrix {cmd:e(attperiods)}, {cmd:predict}
locates the aligned column of the stored ATT matrix {cmd:e(att)}
and copies that period-specific ATT into the new variable. After
grouped point estimation ({cmd:pte, by()} or {cmd:pte, industry()}
without bootstrap), {cmd:predict, att} instead uses the grouped ATT
matrix {cmd:e(att_by)} together with {cmd:e(by)} and {cmd:e(groups)}
so each treated observation receives the ATT path for its own group
rather than the pooled summary. After grouped bootstrap public
results, {cmd:predict, att} falls back to the stored grouped
point-estimate ATT matrix {cmd:e(att_by_point)} with the same
{cmd:e(by)} + {cmd:e(groups)} mapping, because the pooled bootstrap
summary in {cmd:e(att)} does not identify observation-level
group-specific ATT values on its own.
If grouped bootstrap payloads such as {cmd:e(att_mean_pool)},
{cmd:e(att_se_pool)}, {cmd:e(att_boot_g#)}, or {cmd:e(att_se_g#)}
remain active but {cmd:e(att_by_point)} or the grouped route metadata
{cmd:e(by)} / {cmd:e(groups)} are incomplete, {cmd:predict, att}
exits with {cmd:rc=301} rather than silently mapping pooled
{cmd:e(att)}.
On those grouped mapping paths, the current data must still contain the
exact grouping variable name stored in {cmd:e(by)}. Prefix-abbreviation
matches are not accepted, and a renamed or shadow variable cannot be used
to recover the grouped ATT row mapping.
Untreated observations and treated observations outside the
estimated {opt attperiods()} range are set to missing.
If any certified event-time cell is missing from the pooled
{cmd:e(att)} matrix, or from the grouped point matrices
{cmd:e(att_by)} / {cmd:e(att_by_point)}, {cmd:predict, att}
exits with {cmd:rc=198} rather than silently replaying a hole on a
stored ATT path.
If the stored support in {cmd:e(attperiods)} becomes fractional,
duplicated, unsorted, or otherwise non-integer, {cmd:predict, att}
exits with {cmd:rc=198} rather than silently publishing a partially
mapped ATT path.

{pmore}
The ATT estimation stage must have been completed. The final
column of {cmd:e(att)} stores the overall ATT summary and is not
used for observation-level {cmd:predict, att}. Period-specific
scalar aliases such as {cmd:e(att_0)} and {cmd:e(att_1)} may also
be present for compatibility, but the prediction mapping follows
the aligned {cmd:e(attperiods)} + {cmd:e(att)} matrix contract.
The dataset variables {cmd:_pte_treat} and {cmd:_pte_nt} must also
exist: {cmd:_pte_treat} identifies treated observations, and
{cmd:_pte_nt} provides the event time used to align
{cmd:e(attperiods)} with {cmd:e(att)}. If either variable is absent,
re-run {cmd:pte} before calling {cmd:predict, att}.
After {cmd:pte_setup}, the live {cmd:pte} result must also publish a
matching {cmd:e(xtdelta)}; otherwise the stored ATT path is treated as
stale for the current setup-selected panel spacing.


{marker remarks}{...}
{title:Remarks}

{dlgtab:Transition-period exclusion}

{pstd}
A key feature of the CLK framework (Theorem 3.1) is the exclusion
of transition-period observations from the productivity evolution
regression.  A transition period is defined as an observation where
the current treatment status differs from the lagged status
(D_t != D_{t-1}).  The internal variable {cmd:_pte_mid} equals 1
for such observations.  When {opt residuals} is requested,
transition-period observations are set to missing because the
evolution law h_0() is not identified at these points. Treated
post-entry observations are also set to missing because their
realized productivity no longer isolates the untreated innovation.

{dlgtab:Counterfactual simulation}

{pstd}
The {opt tt} statistic relies on Monte Carlo simulation of
counterfactual productivity paths.  For each treated firm, M
paths are drawn using the control-group evolution function h_bar_0
and the estimated innovation distribution.  The number of paths M
is controlled by the {opt nsim()} option in {cmd:pte}. If omitted,
the default is 1 when {cmd:omegapoly(1)} is used and otherwise 100.
Only the untreated evolution parameters (rho_0) are used;
treatment interaction terms are excluded because the counterfactual
asks "what would have happened absent treatment."

{dlgtab:Internal variables}

{pstd}
{cmd:pte} creates the following internal variables in the dataset.
These are used by {cmd:predict} and other postestimation commands:

{p2colset 9 28 30 2}{...}
{p2col:{cmd:_pte_phi}}first-stage fitted value Phi_it{p_end}
{p2col:{cmd:_pte_omega}}recovered productivity omega_it{p_end}
{p2col:{cmd:_pte_eps0}}untreated innovation support epsilon_it{sup:0}{p_end}
{p2col:{cmd:_pte_mid}}transition-period indicator (1 if D_t != D_{t-1}){p_end}
{p2col:{cmd:_pte_nt}}event time relative to treatment adoption{p_end}
{p2col:{cmd:_pte_treat}}treatment group indicator{p_end}
{p2col:{cmd:_pte_tt}}firm-specific treatment effect TT_it on the canonical
trimmed-Gaussian paper track{p_end}
{p2col:{cmd:_pte_tt_raw}}firm-specific treatment effect TT_it on the raw
(untrimmed) track{p_end}
{p2colreset}{...}


{marker examples}{...}
{title:Examples}

{pstd}
{bf:Setup}

{phang2}
{cmd:. pte_example, clear}
{p_end}
{phang2}
{cmd:. xtset firm year}
{p_end}
{phang2}
{cmd:. pte lny, free(lnl) state(lnk) proxy(lnm) treatment(D)}
{p_end}

{pstd}
{bf:1. Recovered productivity (default)}

{phang2}
{cmd:. predict omega_hat}
{p_end}

{pstd}
{bf:2. First-stage fitted value}

{phang2}
{cmd:. predict phi_hat, phi}
{p_end}

{pstd}
{bf:3. Productivity shocks}

{phang2}
{cmd:. predict eps_hat, residuals}
{p_end}

{pstd}
{bf:4. Productivity level in natural units}

{phang2}
{cmd:. predict omega_level, exponential}
{p_end}

{pstd}
{bf:5. Display production function parameters}

{phang2}
{cmd:. predict, parameters}
{p_end}

{pstd}
{bf:6. Firm-specific treatment effects}

{phang2}
{cmd:. predict tt_hat, tt}
{p_end}

{pstd}
{bf:7. Average treatment effect by period}

{phang2}
{cmd:. predict att_hat, att}
{p_end}

{pstd}
{bf:8. Verify transition-period missing values}

{phang2}
{cmd:. predict eps, residuals}
{p_end}
{phang2}
{cmd:. list firm year eps _pte_mid if _pte_mid == 1}
{p_end}
{phang2}
{cmd:. assert missing(eps) if _pte_mid == 1}
{p_end}

{pstd}
{bf:9. Predict with explicit type}

{phang2}
{cmd:. predict double omega_d}
{p_end}
{phang2}
{cmd:. predict double phi_d, phi}
{p_end}

{pstd}
{bf:10. Predict for treated firms only}

{phang2}
{cmd:. predict tt_treated, tt}
{p_end}
{phang2}
{cmd:. summarize tt_treated if _pte_treat == 1}
{p_end}


{marker results}{...}
{title:Stored results}

{pstd}
{cmd:predict} after {cmd:pte} does not store additional results
beyond the new variable.  The postestimation commands rely on the
following stored estimation results:

{synoptset 20 tabbed}{...}
{p2col 5 20 24 2: Scalars}{p_end}
{synopt:{cmd:e(beta_l)}}coefficient on free input (l){p_end}
{synopt:{cmd:e(beta_k)}}coefficient on state variable (k){p_end}
{synopt:{cmd:e(beta_ll)}}coefficient on l^2 (translog only){p_end}
{synopt:{cmd:e(beta_kk)}}coefficient on k^2 (translog only){p_end}
{synopt:{cmd:e(beta_lk)}}coefficient on l*k (translog only){p_end}
{synopt:{cmd:e(omegapoly)}}polynomial order for evolution law{p_end}
{synopt:{cmd:e(xtdelta)}}stored panel time spacing used when residuals restores
{cmd:xtset}, when available{p_end}
{synopt:{cmd:e(att_0)}}compatibility alias for ATT at event time 0, when
stored{p_end}
{synopt:{cmd:e(att_1)}}compatibility alias for ATT at event time 1, when
stored{p_end}
{synopt:{cmd:e(att_}{it:s}{cmd:)}}compatibility alias for ATT at event time
{it:s}, when stored{p_end}
{synopt:{cmd:e(noatt)}}1 if ATT estimation was skipped{p_end}

{p2col 5 20 24 2: Matrices}{p_end}
{synopt:{cmd:e(rho_0)}}control-group evolution parameters{p_end}
{synopt:{cmd:e(rho_by)}}grouped untreated evolution coefficients used by
{cmd:predict, residuals} after grouped estimation, including grouped bootstrap
public reposts when retained{p_end}
{synopt:{cmd:e(attperiods)}}1x(L+1) row vector of exact integer ATT event-time
periods (nt list){p_end}
{synopt:{cmd:e(att)}}1x(L+2) row vector of ATT estimates; last column is overall
ATT{p_end}
{synopt:{cmd:e(att_by)}}grouped point-estimate ATT matrix used by
{cmd:predict, att} after {cmd:pte, by()/industry()}{p_end}
{synopt:{cmd:e(att_by_point)}}grouped point-estimate ATT fallback used by
{cmd:predict, att} after grouped bootstrap public results{p_end}
{synopt:{cmd:e(b_by)}}grouped point-estimate coefficient matrix used by
{cmd:predict, parameters} after {cmd:pte, by()/industry()}{p_end}
{synopt:{cmd:e(beta_boot_g#)}}grouped bootstrap coefficient-draw matrix for
group #, referenced when {cmd:predict, parameters} rejects grouped bootstrap
results{p_end}
{synopt:{cmd:e(beta_se_g#)}}grouped bootstrap coefficient-summary SE row vector
for group #, referenced when {cmd:predict, parameters} rejects grouped bootstrap
results{p_end}

{p2col 5 20 24 2: Macros}{p_end}
{synopt:{cmd:e(cmd)}}{cmd:pte}{p_end}
{synopt:{cmd:e(idvar)}}exact stored panel identifier used by
{cmd:predict, residuals}{p_end}
{synopt:{cmd:e(timevar)}}exact stored time variable used by
{cmd:predict, residuals}{p_end}
{synopt:{cmd:e(id)}}legacy stored panel identifier used as fallback by
{cmd:predict, residuals}{p_end}
{synopt:{cmd:e(time)}}legacy stored time variable used as fallback by
{cmd:predict, residuals}{p_end}
{synopt:{cmd:e(PFtype)}}production function type{p_end}
{synopt:{cmd:e(by)}}grouping variable used by grouped {cmd:predict, residuals}
and {cmd:predict, att}; grouped {cmd:predict, parameters} reports when grouped
labels remain stored in {cmd:e(groups)}{p_end}
{synopt:{cmd:e(groups)}}stored grouped-estimation labels used by grouped
{cmd:predict, residuals} and {cmd:predict, att}, including grouped bootstrap
public reposts that retain grouped mapping payloads; grouped
{cmd:predict, parameters} keeps those labels in {cmd:e(groups)} instead of
reprinting the raw token list{p_end}
{synoptline}


{marker compatibility}{...}
{title:Compatibility with estimation output tools}

{pstd}
Since {cmd:pte} stores results in {cmd:e()}, it is compatible
with standard Stata estimation output tools:

{phang}
{cmd:esttab} and {cmd:estout}: Use {cmd:estimates store} after
{cmd:pte} to save results, then use {cmd:esttab} to create
publication-quality tables.

{phang}
{cmd:outreg2}: Compatible for exporting production function
coefficients.

{pstd}
Example with {cmd:esttab}:

{phang2}{cmd:. pte lnva, free(lnl) state(lnk) proxy(lnm) treatment(D)}{p_end}
{phang2}{cmd:. estimates store pte_model}{p_end}
{phang2}{cmd:. esttab pte_model}{p_end}


{marker references}{...}
{title:References}

{phang}
Chen, X., S. Liao, and K. Schurter. 2026. Productivity
treatment effects. {it:Working Paper}.
{p_end}

{phang}
Ackerberg, D. A., K. Caves, and G. Frazer. 2015.
Identification properties of recent production function
estimators. {it:Econometrica} 83(6): 2411-2451.
{p_end}
