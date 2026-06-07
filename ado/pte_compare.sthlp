{smcl}
{* *! version 1.0.0  01jan2026}{...}
{vieweralsosee "[R] regress" "help regress"}{...}
{vieweralsosee "pte" "help pte"}{...}
{vieweralsosee "pte_graph" "help pte_graph"}{...}
{vieweralsosee "pte_heterogeneity" "help pte_heterogeneity"}{...}
{vieweralsosee "reghdfe" "help reghdfe"}{...}
{viewerjumpto "Syntax" "pte_compare##syntax"}{...}
{viewerjumpto "Description" "pte_compare##description"}{...}
{viewerjumpto "Options" "pte_compare##options"}{...}
{viewerjumpto "Methods" "pte_compare##methods"}{...}
{viewerjumpto "Examples" "pte_compare##examples"}{...}
{viewerjumpto "Stored results" "pte_compare##results"}{...}
{viewerjumpto "References" "pte_compare##references"}{...}
{title:Title}

{p2colset 5 24 26 2}{...}
{p2col:{cmd:pte_compare} {hline 2}}Compare pte with traditional two-step
methods{p_end}
{p2colreset}{...}

{marker syntax}{...}
{title:Syntax}

{p 8 17 2}
{cmd:pte_compare}{cmd:,}
[{it:options}]

{pstd}
{cmd:pte} must be run before calling {cmd:pte_compare}. The treatment
variable and production function inputs are automatically retrieved
from the previous {cmd:pte} estimation.

{pstd}
{cmd:pte_compare} is anchored to the active {cmd:pte} ATT baseline, so
its {opt treatment()} option must match the exact treatment variable
stored by the live {cmd:pte} result. If the active {cmd:e(treatment)} is
missing, or if the caller supplies a different treatment variable name,
{cmd:pte_compare} fail-closes with {cmd:rc=459} instead of mixing the
stored {cmd:pte} ATT baseline with TWFE estimates computed on another
treatment law. When the exact active treatment contract is used,
{cmd:pte_compare} also certifies that the live panel/time/treatment law
still matches the current dataset. That certification now includes the
live panel spacing in {cmd:e(xtdelta)} and a compare-input signature
covering the active depvar/free/state/proxy contract (plus controls when
present), because the compare workers rebuild {cmd:xtset}, rerun
productivity objects on the current data, and then publish bias relative
to the stored {cmd:pte} ATT baseline. If the treatment path, panel
spacing, or compare inputs changed after {cmd:pte} ran, the command
fail-closes with {cmd:rc=459} instead of dispatching a comparison worker
on stale CLK state.

{pstd}
At entry, {cmd:pte_compare} automatically runs {helpb pte_check_deps},
{cmd:compare} so the public router verifies the shared {cmd:reghdfe}
dependency plus the companion compare Mata source files needed by
Methods I and II before dispatching to a method-specific worker. This
gate certifies that those compare Mata sources are both discoverable and
compilable under the public worker contract, and that they publish the
required Method I/II worker-entry Mata symbol. When the active package
source tree is on adopath, the resolver prefers its paired companion
sources over stale installed shadows with the same basename. This
compare gate certifies the compare-only workflow bundle and therefore does
not require the unrelated baseline GMM Mata runtime used by {cmd:pte}.

{synoptset 28 tabbed}{...}
{synopthdr}
{synoptline}
{syntab:Method}
{synopt:{opt m:ethod(string)}}comparison method; default is {cmd:expost}{p_end}
{synopt:{opt all}}alias for {cmd:method(all)}{p_end}

{syntab:Specification}
{synopt:{opt spec:s(numlist)}}TWFE specifications to run: 1, 2, 3; default is
{cmd:specs(1 2 3)}{p_end}
{synopt:{opt omegap:oly(#)}}Method II evolution order; explicit values are
forwarded to {cmd:method(endog)} and {cmd:method(all)}, and omission inherits
the last {cmd:pte} order before falling back to 3{p_end}
{synopt:{opt ab:sorb(varlist)}}fixed effects for reghdfe; default is firm + year
FE{p_end}
{synopt:{opt vce(vcetype)}}variance-covariance estimator for reghdfe{p_end}
{synopt:{opt ind:ustry(string)}}reserved token; rejected for all public methods
because the released comparison API does not implement a general by-industry
path{p_end}

{syntab:Options}
{synopt:{opt treat:ment(varname)}}override treatment variable from {cmd:pte};
the name must match an existing numeric variable exactly, and abbreviation
fallback is rejected{p_end}
{synopt:{opt lagt:reatment}}use lagged treatment L.D instead of the default
contemporaneous D for replication/compatibility paths{p_end}
{synopt:{opt diag:nose}}display bias source analysis (Paper Section 5){p_end}
{synopt:{opt norep:ort}}suppress results table{p_end}
{synoptline}

{marker description}{...}
{title:Description}

{pstd}
{cmd:pte_compare} compares the CLK treatment effect estimates from {cmd:pte}
with traditional two-step approaches that are commonly used in the
applied literature. These traditional methods first estimate a production
function, recover productivity, and then run TWFE regressions of
productivity on treatment status.

{pstd}
The comparison highlights three fundamental problems with the traditional
approach (Paper Section 5):

{phang}1. Unobserved heterogeneity: firms observe both potential productivities
but the econometrician only observes the realized one.{p_end}

{phang}2. Misleading causal interpretation: forcing exogenous productivity
evolution conflates instantaneous effects with dynamic selection.{p_end}

{phang}3. Misleading ATE: TWFE estimates ATE rather than ATT (average treatment
effect on the treated), and conditional unconfoundedness fails at the
transition period.{p_end}

{marker methods}{...}
{title:Methods}

{pstd}
Three comparison methods are available:

{p2colset 5 20 22 2}{...}
{p2col:{cmd:expost}}Method I: Ex-post regression with exogenous productivity
process and TWFE ATT estimation (Paper Section 5, Eq. 18-19).
Production function is re-estimated without CLK correction (no transition
period exclusion, no treatment interaction in evolution).{p_end}

{p2col:{cmd:endog}}Method II: Endogenous productivity process with TWFE.
Re-estimates the production function under the endogenous productivity
specification using the full sample (including transition-period observations),
then runs TWFE instead of counterfactual simulation for ATT (m4-m6).{p_end}

{p2col:{cmd:clktwfe}}Method III: CLK production function with TWFE regression
on CLK-recovered productivity. This method uses the current CLK omega
contract from {cmd:pte}; if the live {cmd:_pte_omega} object is missing or
stale relative to the active {cmd:phi}/{cmd:beta} state, it rebuilds a
temporary current omega before running TWFE. It excludes transition period
observations
using the package's exact non-transition gate {_cmd:_pte_mid==0}. Shadow
leftovers such as {cmd:_pte_mid_shadow} or {cmd:_pte_omega_shadow} are rejected
instead of being consumed through Stata abbreviation binding. Corresponds to
m7-m9 in Table 3.{p_end}

{p2col:{cmd:all}}Run all three methods sequentially and display a combined
comparison table (Table 3 style with m1-m9).{p_end}
{p2colreset}{...}

{pstd}
Method III (clktwfe) key characteristics:

{p 8 12 2}1. Uses the current CLK-corrected productivity contract from
{cmd:pte}, rebuilding a temporary current omega if the exact live
{_cmd:_pte_omega} object is missing or stale{p_end}
{p 8 12 2}2. Excludes transition period observations (D_t != D_{t-1}) using the
exact canonical {_cmd:_pte_mid==0} gate; shadow variables are not
accepted{p_end}
{p 8 12 2}3. Uses contemporaneous treatment D by default, matching equation
(18); {opt lagtreatment} switches Method III to L.D for
replication/compatibility paths{p_end}
{p 8 12 2}4. Addresses Problem 3 (transition period) but not Problems 1-2{p_end}

{pstd}
Each method runs three TWFE specifications:

{pstd}
Across these specifications, all three public methods use the
contemporaneous treatment term D by default, matching equation (18) in
the paper. Supplying {opt lagtreatment} switches the treatment regressor
to L.D for workflows that intentionally reproduce lagged-treatment DO
paths.

{p2colset 5 20 22 2}{...}
{p2col:Spec 1}No lagged controls: reghdfe omega D, absorb(firm year){p_end}
{p2col:Spec 2}First-order lag: reghdfe omega L.omega D, absorb(firm year){p_end}
{p2col:Spec 3}Third-order polynomial lags: reghdfe omega L.omega L.omega2
L.omega3 D, absorb(firm year){p_end}
{p2colreset}{...}

{marker options}{...}
{title:Options}

{dlgtab:Method}

{phang}
{opt method(string)} specifies the comparison method. Canonical values are
{cmd:expost} (default), {cmd:endog}, {cmd:clktwfe}, and {cmd:all}. The
public router also accepts compatibility aliases {cmd:endogenous} for
{cmd:endog} and {cmd:clk_twfe} for {cmd:clktwfe}.

{phang}
{opt all} is a convenience alias for {cmd:method(all)}.
It may not be combined with another explicit {opt method()} value.

{dlgtab:Specification}

{phang}
{opt specs(numlist)} specifies which TWFE specifications to run.
Default is {cmd:specs(1 2 3)} for all three. Use {cmd:specs(3)} to run
only the third-order polynomial specification. This option applies to
the standalone methods {cmd:method(expost)}, {cmd:method(endog)}, and
{cmd:method(clktwfe)}. The combined {cmd:method(all)} workflow always
requires the full Table 3 bundle {cmd:specs(1 2 3)} and rejects subset
specification requests. For the standalone methods, every requested
specification must also finish successfully; if one requested TWFE
regression fails, {cmd:pte_compare} fail-closes instead of publishing a
partial compare result.

{phang}
{opt omegapoly(#)} sets the evolution polynomial order used by
{cmd:method(endog)}. Explicit values are also forwarded through
{cmd:method(all)} to keep Method II on the same comparison design.
When the option is omitted, {cmd:pte_compare} inherits the active
{cmd:e(omegapoly)} from the preceding {cmd:pte} estimation; if that
state is unavailable, the public fallback is {cmd:3}. This option has
no effect on {cmd:method(expost)} or {cmd:method(clktwfe)}.

{phang}
{opt absorb(varlist)} specifies the fixed effects for {cmd:reghdfe}.
Default is firm and year fixed effects (the panel and time variables
from the active {cmd:pte} panel contract). The compare workers
temporarily align {cmd:xtset} to that contract for lag operators and
inherit live {cmd:e(xtdelta)} when it is available, so {cmd:L.} operators
follow the same panel-spacing law as the active {cmd:pte} baseline, and
then restore the caller's ambient {cmd:xtset} state before returning.

{phang}
{opt vce(vcetype)} specifies the variance-covariance estimator passed
to {cmd:reghdfe}. Default is the {cmd:reghdfe} default (robust).

{phang}
{opt industry(string)} is currently reserved for future comparison
extensions. It is rejected for all public methods because the paper/DO
comparison workflow uses explicit sample splits (for example, full sample
versus the electronics industry) rather than a general by-industry public
API. Subset the data first if an industry-specific comparison is required.

{dlgtab:Options}

{phang}
{opt treatment(varname)} overrides the treatment variable. By default,
the treatment variable is retrieved from the previous {cmd:pte} estimation.
When supplied explicitly, the name must match an existing numeric treatment
column exactly. The public router rejects Stata unique-abbreviation fallback,
so {cmd:treatment(D)} will not silently bind to {cmd:D_shadow}. Because
the comparison table is defined relative to the active {cmd:pte} ATT
baseline, the explicit {opt treatment()} variable must also be the same
exact variable stored in {cmd:e(treatment)}. To compare a different
treatment contract, re-run {cmd:pte} with that {opt treatment()} first.
When the exact active treatment variable is used, the router certifies
the live treatment law against the current dataset before dispatch. That
entry gate also certifies live {cmd:e(xtdelta)} against the exact
current data spacing so the downstream {cmd:L.} operators cannot run
under a stale lag law.

{phang}
{opt lagtreatment} is retained for backward compatibility with
lagged-treatment reproduction paths. By default, the public comparison
regressions use the contemporaneous treatment indicator D in equation
(18). Supplying {opt lagtreatment} changes the treatment regressor in
the three comparison methods to L.D while leaving lagged productivity
controls unchanged.

{phang}
{opt diagnose} displays a detailed bias source analysis based on
Paper Section 5, including the three fundamental problems and expected
bias directions from Table E.5. If {cmd:pte} ATT estimates are available,
quantitative bias comparisons are also shown.

{phang}
{opt noreport} suppresses the results table output.

{marker examples}{...}
{title:Examples}

{pstd}
Note: {cmd:pte_compare} requires {cmd:reghdfe} to be installed.
Run {cmd:pte_check_deps, compare} to verify.{p_end}

{pstd}Setup{p_end}
{phang2}{cmd:. pte_example, clear}{p_end}
{phang2}{cmd:. xtset firm year}{p_end}
{phang2}{cmd:. pte lnva, free(lnl) state(lnk) proxy(lnm) treatment(D)}{p_end}

{pstd}Default comparison (ex-post method, all specs){p_end}
{phang2}{cmd:. pte_compare}{p_end}

{pstd}Ex-post method with diagnostics{p_end}
{phang2}{cmd:. pte_compare, method(expost) diagnose}{p_end}

{pstd}Run only specification 3{p_end}
{phang2}{cmd:. pte_compare, method(expost) specs(3)}{p_end}

{pstd}Endogenous comparison with the same live order as the last {cmd:pte}
fit{p_end}
{phang2}{cmd:. pte_compare, method(endog)}{p_end}

{pstd}Override Method II to fourth-order evolution{p_end}
{phang2}{cmd:. pte_compare, method(endog) omegapoly(4)}{p_end}

{pstd}All three methods{p_end}
{phang2}{cmd:. pte_compare, method(all)}{p_end}

{pstd}All three methods with Method II forced to first-order evolution{p_end}
{phang2}{cmd:. pte_compare, all omegapoly(1)}{p_end}

{pstd}With custom fixed effects and VCE{p_end}
{phang2}{cmd:. pte_compare, method(expost) absorb(firm year industry) vce(cluster firm)}{p_end}

{pstd}Lagged-treatment compatibility path{p_end}
{phang2}{cmd:. pte_compare, method(expost) lagtreatment}{p_end}

{pstd}CLK+TWFE method (Method III){p_end}
{phang2}{cmd:. pte_compare, method(clktwfe)}{p_end}

{pstd}CLK+TWFE with only specification 3 (m9){p_end}
{phang2}{cmd:. pte_compare, method(clktwfe) specs(3)}{p_end}

{marker results}{...}
{title:Stored results}

{pstd}
{cmd:pte_compare} stores the following in {cmd:e()}:

{synoptset 28 tabbed}{...}
{p2col 5 28 32 2: Macros (all methods)}{p_end}
{synopt:{cmd:e(cmd)}}{cmd:pte_compare}{p_end}
{synopt:{cmd:e(method)}}comparison method used{p_end}
{synopt:{cmd:e(treatment)}}treatment variable name{p_end}
{synopt:{cmd:e(absorb)}}fixed effects specification{p_end}
{synopt:{cmd:e(specs)}}specifications run{p_end}

{pstd}
When {cmd:method(expost)} is specified, results are stored:

{synoptset 28 tabbed}{...}
{p2col 5 28 32 2: Scalars}{p_end}
{synopt:{cmd:e(att_expost_1)}}Spec 1 treatment coefficient{p_end}
{synopt:{cmd:e(att_expost_2)}}Spec 2 treatment coefficient{p_end}
{synopt:{cmd:e(att_expost_3)}}Spec 3 treatment coefficient{p_end}
{synopt:{cmd:e(se_expost_1)}}Spec 1 standard error{p_end}
{synopt:{cmd:e(se_expost_2)}}Spec 2 standard error{p_end}
{synopt:{cmd:e(se_expost_3)}}Spec 3 standard error{p_end}
{synopt:{cmd:e(fval_expost)}}GMM objective function value{p_end}

{p2col 5 28 32 2: Matrices}{p_end}
{synopt:{cmd:e(coef_expost)}}1x3 coefficient vector (spec1, spec2, spec3){p_end}
{synopt:{cmd:e(se_expost)}}1x3 standard error vector{p_end}
{synopt:{cmd:e(ci_expost)}}3x2 confidence interval matrix (lower, upper){p_end}
{synopt:{cmd:e(r2_expost)}}1x3 adjusted R-squared vector{p_end}
{synopt:{cmd:e(n_expost)}}1x3 sample size vector{p_end}
{synopt:{cmd:e(beta_expost)}}1x5 production function coefficients (beta_l,
beta_k, beta_ll, beta_kk, beta_lk){p_end}
{synopt:{cmd:e(compare_coef)}}1x3 coefficient vector for chart interface{p_end}
{synopt:{cmd:e(compare_se)}}1x3 SE vector for chart interface{p_end}

{pstd}
When {cmd:method(all)} is specified, results from all methods are stored
with prefixes {cmd:expost_}, {cmd:endog_}, and {cmd:clktwfe_}. Additional
combined matrices are also stored. On the current live path,
{cmd:method(all)} republishes the per-method coefficient/SE matrices
({cmd:e(coef_expost)} / {cmd:e(se_expost)} / {cmd:e(coef_endog)} /
{cmd:e(se_endog)} / {cmd:e(coef_clktwfe)} / {cmd:e(se_clktwfe)}), but it
does {bf:not} republish the single-method-only matrices
{cmd:e(ci_expost)}, {cmd:e(r2_expost)}, {cmd:e(n_expost)}, or
{cmd:e(beta_expost)} from the standalone {cmd:method(expost)} result.

{synoptset 28 tabbed}{...}
{p2col 5 28 32 2: Matrices (method all)}{p_end}
{synopt:{cmd:e(coef_all)}}1x9 coefficient vector (m1-m9){p_end}
{synopt:{cmd:e(se_all)}}1x9 standard error vector{p_end}
{synopt:{cmd:e(t_all)}}1x9 t-statistic vector{p_end}
{synopt:{cmd:e(p_all)}}1x9 p-value vector{p_end}
{synopt:{cmd:e(ci_lower)}}1x9 CI lower bound vector (95%){p_end}
{synopt:{cmd:e(ci_upper)}}1x9 CI upper bound vector (95%){p_end}
{synopt:{cmd:e(bias_all)}}1x9 bias vs pte (%) vector{p_end}
{synopt:{cmd:e(n_all)}}1x9 sample size vector{p_end}
{synopt:{cmd:e(r2_all)}}1x9 adjusted R-squared vector{p_end}
{synopt:{cmd:e(spec_all)}}1x9 specification indicator (1,2,3,1,2,3,1,2,3){p_end}
{synopt:{cmd:e(compare_coef)}}9x1 coefficient vector for
{cmd:pte_graph, compare}{p_end}
{synopt:{cmd:e(compare_ci_lower)}}9x1 CI lower bound vector for
{cmd:pte_graph, compare}{p_end}
{synopt:{cmd:e(compare_ci_upper)}}9x1 CI upper bound vector for
{cmd:pte_graph, compare}{p_end}
{synopt:{cmd:e(compare_spec)}}9x1 specification indicator for
{cmd:pte_graph, compare}{p_end}

{p2col 5 28 32 2: Scalars (method all)}{p_end}
{synopt:{cmd:e(att_m1)}}m1 treatment coefficient{p_end}
{synopt:{cmd:e(att_m2)}}m2 treatment coefficient{p_end}
{synopt:{cmd:e(att_m3)}}m3 treatment coefficient{p_end}
{synopt:{cmd:e(att_m4)}}m4 treatment coefficient{p_end}
{synopt:{cmd:e(att_m5)}}m5 treatment coefficient{p_end}
{synopt:{cmd:e(att_m6)}}m6 treatment coefficient{p_end}
{synopt:{cmd:e(att_m7)}}m7 treatment coefficient{p_end}
{synopt:{cmd:e(att_m8)}}m8 treatment coefficient{p_end}
{synopt:{cmd:e(att_m9)}}m9 treatment coefficient{p_end}
{synopt:{cmd:e(omegapoly)}}Method II evolution order used inside
{cmd:method(all)}{p_end}
{synopt:{cmd:e(pte_att)}}pte ATT reference value, posted only when the upstream
{cmd:pte} result carried an ATT estimate{p_end}

{pstd}
When {cmd:method(endog)} is specified, additional results are stored:

{synoptset 28 tabbed}{...}
{p2col 5 28 32 2: Scalars (endog)}{p_end}
{synopt:{cmd:e(att_endog_1)}}Spec 1 (m4) treatment coefficient{p_end}
{synopt:{cmd:e(att_endog_2)}}Spec 2 (m5) treatment coefficient{p_end}
{synopt:{cmd:e(att_endog_3)}}Spec 3 (m6) treatment coefficient{p_end}
{synopt:{cmd:e(se_endog_1)}}Spec 1 standard error{p_end}
{synopt:{cmd:e(se_endog_2)}}Spec 2 standard error{p_end}
{synopt:{cmd:e(se_endog_3)}}Spec 3 standard error{p_end}
{synopt:{cmd:e(fval_endog)}}GMM objective function value{p_end}
{synopt:{cmd:e(omegapoly)}}evolution polynomial order used by Method II{p_end}

{p2col 5 28 32 2: Matrices (endog)}{p_end}
{synopt:{cmd:e(coef_endog)}}1x3 coefficient vector{p_end}
{synopt:{cmd:e(se_endog)}}1x3 standard error vector{p_end}
{synopt:{cmd:e(ci_endog)}}3x2 confidence interval matrix{p_end}
{synopt:{cmd:e(r2_endog)}}1x3 adjusted R-squared vector{p_end}
{synopt:{cmd:e(n_endog)}}1x3 sample size vector{p_end}
{synopt:{cmd:e(beta_endog)}}1x5 production-function coefficient vector{p_end}

{pstd}
When {cmd:method(clktwfe)} is specified, additional results are stored:

{synoptset 28 tabbed}{...}
{p2col 5 28 32 2: Scalars (clktwfe)}{p_end}
{synopt:{cmd:e(att_clk_twfe_1)}}Spec 1 (m7) treatment coefficient{p_end}
{synopt:{cmd:e(att_clk_twfe_2)}}Spec 2 (m8) treatment coefficient{p_end}
{synopt:{cmd:e(att_clk_twfe_3)}}Spec 3 (m9) treatment coefficient{p_end}
{synopt:{cmd:e(se_clk_twfe_1)}}Spec 1 standard error{p_end}
{synopt:{cmd:e(se_clk_twfe_2)}}Spec 2 standard error{p_end}
{synopt:{cmd:e(se_clk_twfe_3)}}Spec 3 standard error{p_end}
{synopt:{cmd:e(N_clk_twfe)}}number of observations{p_end}
{synopt:{cmd:e(bias_clk_twfe)}}relative bias vs pte (%){p_end}

{p2col 5 28 32 2: Matrices (clktwfe)}{p_end}
{synopt:{cmd:e(coef_clk_twfe)}}1x3 coefficient vector{p_end}
{synopt:{cmd:e(se_clk_twfe)}}1x3 standard error vector{p_end}
{synopt:{cmd:e(ci_clk_twfe)}}3x2 confidence interval matrix{p_end}
{synopt:{cmd:e(r2_clk_twfe)}}1x3 adjusted R-squared vector{p_end}
{synopt:{cmd:e(n_clk_twfe)}}1x3 sample size vector{p_end}

{pstd}
Individual reghdfe estimates are stored as {cmd:_expost_m1}, {cmd:_expost_m2},
{cmd:_expost_m3} and can be used with {cmd:esttab}:

{phang2}{cmd:. esttab _expost_m1 _expost_m2 _expost_m3, keep(*D*)}{p_end}

{pstd}
These named estimates are published only after the requested compare bundle
finishes successfully. If a rerun fails, {cmd:pte_compare} fail-closes by
removing partial estimates created during the failed attempt and restoring any
same-name compare estimates that existed before the rerun.

{marker references}{...}
{title:References}

{phang}
Chen, X., Liao, Z. & Schurter, K. (2026).
Productivity Treatment Effects.
{it:Working Paper}. Section 5, Section 6.4.3, Table E.5.
{p_end}

{title:Also see}

{psee}
{space 2}Help:  {help pte:pte}, {help reghdfe:reghdfe}
{p_end}
