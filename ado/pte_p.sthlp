{smcl}
{* *! version 1.0.0  19mar2026}{...}
{vieweralsosee "[R] predict" "help predict"}{...}
{vieweralsosee "pte" "help pte"}{...}
{vieweralsosee "pte_graph" "help pte_graph"}{...}
{vieweralsosee "pte_diagnose" "help pte_diagnose"}{...}
{viewerjumpto "Syntax" "pte_p##syntax"}{...}
{viewerjumpto "Description" "pte_p##description"}{...}
{viewerjumpto "Options" "pte_p##options"}{...}
{viewerjumpto "Examples" "pte_p##examples"}{...}
{viewerjumpto "Remarks" "pte_p##remarks"}{...}
{viewerjumpto "Stored results" "pte_p##results"}{...}
{viewerjumpto "References" "pte_p##references"}{...}
{viewerjumpto "Also see" "pte_p##alsosee"}{...}

{title:Title}

{p2colset 5 20 22 2}{...}
{p2col:{cmd:pte predict} {hline 2}}Postestimation predictions after pte{p_end}
{p2colreset}{...}

{marker syntax}{...}
{title:Syntax}

{p 8 17 2}
{cmd:predict} [{it:type}] {newvar} [{cmd:if}] [{cmd:in}]
[{cmd:,} {it:statistic}]

{p 8 17 2}
{cmd:predict} [{cmd:,} {cmd:parameters}]

{synoptset 20 tabbed}{...}
{synopthdr:statistic}
{synoptline}
{synopt:{opt omega}}productivity omega_it (default){p_end}
{synopt:{opt phi}}control-adjusted first-stage productivity proxy phi_it{p_end}
{synopt:{opt res:iduals}}untreated innovation support epsilon_it{sup:0}{p_end}
{synopt:{opt exp:onential}}productivity level exp(omega_it){p_end}
{synopt:{opt tt}}firm-specific treatment effect TT_it{p_end}
{synopt:{opt att}}average treatment effect ATT by event time{p_end}
{synopt:{opt par:ameters}}display production-function parameters (no variable
created){p_end}
{synoptline}

{pstd}
At most one statistic option can be specified per call. If omitted,
{cmd:omega} is used by default.

{marker description}{...}
{title:Description}

{pstd}
{cmd:predict} after {cmd:pte} generates postestimation objects from
the stored {cmd:e()} results and internal variables created by
{cmd:pte}. The default prediction is {cmd:omega}.

{pstd}
All options except {cmd:parameters} create a new variable.
{cmd:parameters} prints the production-function coefficients and does
not generate a variable.
When a storage type is supplied, it must be numeric
({cmd:byte}, {cmd:int}, {cmd:long}, {cmd:float}, or {cmd:double});
string types are rejected.

{pstd}
After {cmd:pte_setup}, {cmd:predict} also enforces the stored
panel/time/treatment contract in
{cmd:_dta[_pte_setup_panelvar]},
{cmd:_dta[_pte_setup_timevar]},
{cmd:_dta[_pte_setup_treatment]},
{cmd:_dta[_pte_setup_treatsig]}, and
{cmd:_dta[_pte_setup_xtdelta]}. For
{cmd:omega}, {cmd:phi}, {cmd:exponential}, {cmd:parameters},
{cmd:tt}, and {cmd:att}, the live {cmd:pte} result must publish
panel metadata through {cmd:e(idvar)} / {cmd:e(timevar)} or the
legacy {cmd:e(id)} / {cmd:e(time)} aliases, plus a matching
{cmd:e(treatsig)} and {cmd:e(xtdelta)}. If any of those live
certification fields are absent or conflict with the stored
setup-selected law, {cmd:predict} stops rather than mixing stale
postestimation state with the current setup contract. It also
re-certifies the current data against the stored
{cmd:_dta[_pte_setup_treatsig]} fingerprint, so a failed
{cmd:pte_setup} rerun cannot leave {cmd:predict} trusting an older
restored contract after the treatment path has changed. The
live aliases are certification fields, not literal placeholders:
dot-sentinel payloads such as {cmd:e(idvar)="."},
{cmd:e(timevar)="."}, {cmd:e(treatment)="."}, and
{cmd:e(treatsig)="."} are treated as missing before that setup/live
comparison is evaluated. The
stored {cmd:_dta[_pte_setup_treatment]} name remains part of the
dataset-scoped contract, but the live treatment-side certification
path is law-first: {cmd:e(treatment)} may be omitted when
{cmd:e(treatsig)} already certifies the same treatment law. If
{cmd:e(treatment)} is present and names a different treatment
variable than the stored setup contract, {cmd:predict} still fails
closed with {cmd:rc=459}. Without a stored {cmd:pte_setup} contract,
the same law-first guard now applies to a pure live {cmd:pte} result:
if the live state publishes any current-law fragment
({cmd:e(idvar)}, {cmd:e(timevar)}, {cmd:e(treatment)},
{cmd:e(treatsig)}, or {cmd:e(xtdelta)}), it must publish a complete
{cmd:e(idvar)/e(timevar)/e(treatment)/e(treatsig)} bundle and that
bundle is re-certified against the current data before {cmd:predict}
maps {cmd:tt} or {cmd:att}. This means stale live {cmd:e(treatsig)}
state and pure-live {cmd:e(treatsig)}-only claimants now fail closed
with {cmd:rc=459} instead of publishing TT/ATT values on an
uncertified treatment path. The
{cmd:residuals} branch keeps its documented legacy fallback and may
rebuild lagged omega from the setup-stored delta when older live
results do not yet publish {cmd:e(xtdelta)}.

{marker options}{...}
{title:Options}

{phang}
{opt omega} returns recovered productivity from {cmd:_pte_omega}. This
is the default.

{phang}
{opt phi} returns the control-adjusted first-stage productivity proxy
from {cmd:_pte_phi}. If {cmd:pte} was run with {opt control()}, those
controls are already removed from the stored {cmd:phi}.

{phang}
{opt residuals} returns untreated innovation support. If
{cmd:_pte_eps0} exists, stored values are used when available.
If the exact support indicator {cmd:_pte_eps0_ind} also exists, it
remains the final support boundary on that stored path as well, so
stale nonmissing values of {cmd:_pte_eps0} outside the identified
untreated support are still returned as missing.
If {cmd:_pte_eps0} survives but {cmd:_pte_eps0_ind} does not,
{cmd:predict, residuals} now stops rather than guessing the support
from broader bridge variables such as {cmd:_pte_active_sample}; that
bridge marks the live EPIC-002 activity set, not the exact untreated
innovation sample.
Otherwise, shocks are computed
from {cmd:_pte_omega} and the stored untreated evolution law using
lagged omega under the stored panel declaration from
{cmd:e(idvar)} / {cmd:e(timevar)}, with fallback to {cmd:e(id)} /
{cmd:e(time)} when the newer aliases are not present. After {cmd:pte_setup},
the fallback also requires a complete stored setup contract, including the
resolved {cmd:delta()} published in {cmd:_dta[_pte_setup_xtdelta]}. When a
legacy live {cmd:pte} result lacks {cmd:e(xtdelta)}, {cmd:predict, residuals}
uses that setup-stored delta to rebuild lagged omega. Without either
{cmd:e(xtdelta)} or the setup-stored delta, the command infers the panel
spacing from the exact current {cmd:e(idvar)}/{cmd:e(timevar)} data when that
spacing is uniquely identified; otherwise it stops rather than borrowing the
caller's ambient {cmd:xtset} spacing. If the live
{cmd:e(xtdelta)} and the setup-stored delta disagree, the command stops
rather than mixing two lag laws. The exact stored panel and time variable
names must still exist in the current data; prefix-abbreviation matches are
not accepted on this fallback path. On the serial
path, this fallback consumes {cmd:e(rho_0)}. After grouped point
estimation ({cmd:pte, by()} or {cmd:pte, industry()} without bootstrap),
if {cmd:_pte_eps0} is absent the fallback instead uses
{cmd:e(rho_by)} together with the exact current grouping variable named
in {cmd:e(by)} so each observation is rebuilt from its own group's
untreated law. On that grouped fallback, {cmd:predict, residuals}
uses the stored estimation-time group order in {cmd:e(groups)} to map
rows of {cmd:e(rho_by)} back to the current data, so the current data
may be a subset of the original grouped sample without remapping those
rows. Grouped bootstrap public results also support that grouped
fallback when the public repost retains {cmd:e(rho_by)} together with
{cmd:e(by)} and {cmd:e(groups)}.
When {cmd:_pte_eps0} is absent but the exact support indicator
{cmd:_pte_eps0_ind} exists, the fallback path still returns nonmissing
values only on the stored untreated-innovation support
({cmd:_pte_eps0_ind==1}), so
{cmd:eps0window()} and related sample restrictions remain binding. When
the grouped fallback is used, the grouped untreated-law mapping is
applied first and the same support mask still remains binding.
If {cmd:eps0window()>0} and the current data contain neither
{cmd:_pte_eps0} nor {cmd:_pte_eps0_ind}, {cmd:predict, residuals}
cannot rebuild eps0 safely because the window-restricted untreated
support is no longer observable. Re-run pte before predict, residuals,
or keep _pte_eps0/_pte_eps0_ind in the current data.
Likewise, if both {cmd:_pte_eps0_ind} and {cmd:_pte_active_sample}
are absent on the fallback path, reconstruction is rejected because
even the minimum EPIC-002 support boundary is no longer observable.
Treated post-entry observations ({cmd:_pte_treat==1} with
{cmd:_pte_nt>=0}) are returned missing because realized productivity
there already embeds treatment effects rather than the untreated
innovation. If event time is unavailable, {cmd:predict, residuals}
falls back to masking current treated observations using {cmd:_pte_D},
and then to masking all ever-treated observations using
{cmd:_pte_treat}. Transition observations ({cmd:_pte_mid==1}) are also
set to missing.

{phang}
{opt exponential} returns {cmd:exp(_pte_omega)}.

{phang}
{opt tt} returns firm-time treatment effects from {cmd:_pte_tt}, with
missing values for controls, treated pre-period observations
({cmd:_pte_nt<0}), and treated observations whose event time is unknown
({cmd:missing(_pte_nt)}). Only treated observations whose event times
appear in the stored support matrix {cmd:e(attperiods)} receive
nonmissing values; stale {cmd:_pte_tt} values outside that exact
support remain missing. Requires ATT estimation (that is, {cmd:pte}
was not run with {cmd:noatt}) plus the internal variables
{cmd:_pte_treat} and {cmd:_pte_nt}, and the stored ATT support matrix
{cmd:e(attperiods)}. If the stored support becomes fractional,
negative, duplicated, unsorted, or otherwise non-integer, {cmd:predict, tt}
exits with {cmd:rc=198} instead of publishing a partially mapped TT
surface. Likewise, if any event time listed in {cmd:e(attperiods)}
has zero nonmissing treated {cmd:_pte_tt} observations, {cmd:predict, tt}
fails closed with {cmd:rc=198} instead of creating a partially empty
certified TT path.

{phang}
{opt att} maps period ATT estimates from {cmd:e(attperiods)} and
{cmd:e(att)} to treated observations by event time ({cmd:_pte_nt}).
After grouped point estimation ({cmd:pte, by()} or {cmd:pte, industry()}
without bootstrap), {cmd:predict, att} instead uses the grouped ATT
matrix {cmd:e(att_by)} together with {cmd:e(by)} and {cmd:e(groups)} so
each treated observation receives its own group's ATT path rather than
the pooled summary.
After grouped bootstrap public results, {cmd:predict, att} falls back to
the stored grouped point-estimate ATT matrix {cmd:e(att_by_point)} with
the same {cmd:e(by)} + {cmd:e(groups)} mapping, because the pooled
bootstrap summary in {cmd:e(att)} does not identify observation-level
group-specific ATT values on its own.
If grouped bootstrap payloads such as {cmd:e(att_mean_pool)},
{cmd:e(att_se_pool)}, {cmd:e(att_boot_g#)}, or {cmd:e(att_se_g#)}
remain active but {cmd:e(att_by_point)} or the grouped route metadata
{cmd:e(by)} / {cmd:e(groups)} are incomplete, {cmd:predict, att}
exits with {cmd:rc=301} instead of silently broadcasting the pooled
summary to all treated observations.
On those grouped mapping paths, the current data must still contain the
exact grouping variable name stored in {cmd:e(by)}. Prefix-abbreviation
matches are not accepted, and a renamed or shadow variable cannot be used
to recover the grouped ATT row mapping.
Only treated observations with event times listed in
{cmd:e(attperiods)} receive values. The final pooled ATT column of
{cmd:e(att)} is intentionally excluded from observation-level mapping.
That exact support is fail-closed rather than partially replayed: if any
supported pooled {cmd:e(att)} cell is missing, or if any grouped
{cmd:e(att_by)} / {cmd:e(att_by_point)} cell is missing on a listed
event time, {cmd:predict, att} exits with {cmd:rc=198} instead of
silently leaving holes on a certified ATT path.
Requires ATT estimation plus the internal variables {cmd:_pte_treat}
and {cmd:_pte_nt}. {cmd:_pte_treat} identifies treated observations,
and {cmd:_pte_nt} supplies the event time used to align
{cmd:e(attperiods)} with {cmd:e(att)}. If either variable is absent,
re-run {cmd:pte} before calling {cmd:predict, att}. If the stored
event-time support becomes fractional, negative, duplicated, unsorted,
or otherwise non-integer, {cmd:predict, att} exits with {cmd:rc=198}
instead of silently publishing a partially mapped ATT path.

{phang}
{opt parameters} displays production-function coefficients. For
Cobb-Douglas it prints {cmd:beta_l}, {cmd:beta_k}, and returns to
scale. For translog it prints {cmd:beta_l}, {cmd:beta_k},
{cmd:beta_ll}, {cmd:beta_kk}, and {cmd:beta_lk}, plus the symbolic
elasticity formulas shown in the Results window. When the serial/public
result also stores time-trend or other control coefficients in
{cmd:e(beta_controls)}, {cmd:predict, parameters} prints those control
coefficients as well; the single-control benchmark path is echoed as
{cmd:beta_t}. The current public implementation does {bf:not} evaluate
those elasticities numerically at sample means. No variable is created.
After grouped point estimation
({cmd:pte, by()} or {cmd:pte, industry()} without bootstrap),
{cmd:predict, parameters} prints the stored group-specific coefficient
matrix {cmd:e(b_by)}. After grouped bootstrap results, it remains
unavailable because the public result stores coefficient draws
({cmd:e(beta_boot_g#)}) and grouped coefficient-summary SE vectors
({cmd:e(beta_se_g#)}) rather than one public point-estimate matrix. If
any of those grouped bootstrap coefficient payloads remain active,
{cmd:predict, parameters} exits with {cmd:rc=198} instead of falling
back to serial {cmd:e(beta_*)} scalars or a stale grouped
{cmd:e(b_by)} surface.
Because this is a reporting action over stored {cmd:e()} results rather
than an observation-level prediction, {cmd:if} and {cmd:in} qualifiers
are not allowed.

{marker examples}{...}
{title:Examples}

{phang2}{cmd:. pte_example, clear}{p_end}
{phang2}{cmd:. xtset firm year}{p_end}
{phang2}{cmd:. pte lnva, free(lnl) state(lnk) proxy(lnm) treatment(D)}{p_end}

{pstd}Default prediction (omega){p_end}
{phang2}{cmd:. predict omega_hat}{p_end}

{pstd}Productivity level{p_end}
{phang2}{cmd:. predict tfp_level, exponential}{p_end}

{pstd}Untreated innovation support{p_end}
{phang2}{cmd:. predict eps_hat, residuals}{p_end}

{pstd}Treatment effects{p_end}
{phang2}{cmd:. predict tt_hat, tt}{p_end}
{phang2}{cmd:. predict att_hat, att}{p_end}

{pstd}Display coefficients only{p_end}
{phang2}{cmd:. predict, parameters}{p_end}

{marker remarks}{...}
{title:Remarks}

{dlgtab:Residual support}

{pstd}
For the CLK correction, transition periods are identified by
{it:D_it != D_{i,t-1}} and tracked by {cmd:_pte_mid}. In
{cmd:predict, residuals}, transition observations are treated as
outside the identified innovation support and are returned as
missing. Treated post-entry observations are also returned as
missing because realized productivity there already embeds treatment
effects and is not an untreated innovation. If the dataset still
contains the exact variable {cmd:_pte_eps0_ind}, that indicator remains
the support boundary both when {cmd:predict, residuals} reads stored
{cmd:_pte_eps0} values and when it must rebuild values from {cmd:e(rho_0)}
because {cmd:_pte_eps0} is absent.

{dlgtab:ATT/TT support}

{pstd}
{cmd:predict, tt} and {cmd:predict, att} are only available when ATT was
estimated ({cmd:e(noatt)==0}). Both rely on internal ATT artifacts
created by {cmd:pte}; re-running {cmd:pte} is required if these objects
are absent from the current dataset/session. For both commands, the
current event time {cmd:_pte_nt} is interpreted against the exact
stored support in {cmd:e(attperiods)} rather than against a continuous
{cmd:0..max(_pte_nt)} window. For {cmd:predict, tt}, those supported
periods must also remain realized in the stored {cmd:_pte_tt} bridge:
an event time listed in {cmd:e(attperiods)} cannot be completely empty
for treated observations.

{dlgtab:Grouped estimation}

{pstd}
After benchmark-by estimation ({cmd:pte, by()} or {cmd:pte, industry()}),
the public point-estimate result stores one production-function
coefficient vector per group in {cmd:e(b_by)}. On that path,
{cmd:predict, parameters} prints the grouped coefficient matrix rather
than forcing manual {cmd:ereturn} inspection. The grouped point-estimate
ATT path is also exposed through {cmd:e(att_by)}, and {cmd:predict, att}
uses {cmd:e(by)} + {cmd:e(groups)} to map those group-specific ATT
profiles back to observations. Grouped bootstrap results store
coefficient draws in {cmd:e(beta_boot_g#)} and grouped coefficient-summary
SE vectors in {cmd:e(beta_se_g#)} instead of a single point-estimate
matrix, so {cmd:predict, parameters} remains unavailable there. However,
with a single explicit {cmd:control()} variable, those grouped
coefficient payloads keep the legacy {cmd:beta_t} slot; with multiple
explicit controls, they append the exact control names after the
structural coefficients. However,
grouped bootstrap public results still keep the grouped point ATT path in
{cmd:e(att_by_point)}, and {cmd:predict, att} falls back to that matrix
for observation-level ATT mapping. If grouped bootstrap payloads such as
{cmd:e(att_mean_pool)}, {cmd:e(att_se_pool)}, {cmd:e(att_boot_g#)}, or
{cmd:e(att_se_g#)} remain active but the grouped point surface or grouped
route metadata are incomplete, {cmd:predict, att} exits with
{cmd:rc=301} rather than silently falling back to pooled {cmd:e(att)}.
On both grouped ATT paths, the current data must still contain the exact
grouping variable named in {cmd:e(by)}; prefix-abbreviation matches are
rejected, and if that exact variable is no longer present you must
restore it or re-run {cmd:pte} before calling {cmd:predict, att}.

{marker results}{...}
{title:Stored results}

{pstd}
{cmd:predict} after {cmd:pte} does not modify {cmd:e()}. It relies on:

{pstd}
{it:Scalars}

{synoptset 22 tabbed}{...}
{synopt:{cmd:e(omegapoly)}}evolution-polynomial order{p_end}
{synopt:{cmd:e(noatt)}}1 when ATT stage was skipped{p_end}
{synopt:{cmd:e(eps0window)}}stored untreated-innovation support window used by
{cmd:predict, residuals} to guard residual fallback when {cmd:_pte_eps0} /
{cmd:_pte_eps0_ind} are absent{p_end}
{synopt:{cmd:e(xtdelta)}}stored panel time spacing used when residual fallback
restores {cmd:xtset}, when available{p_end}
{synopt:{cmd:e(beta_l)}}free-input coefficient; available on non-grouped results
only{p_end}
{synopt:{cmd:e(beta_k)}}state-input coefficient; available on non-grouped
results only{p_end}
{synopt:{cmd:e(beta_ll)}}translog free-input quadratic coefficient; available on
non-grouped translog results only{p_end}
{synopt:{cmd:e(beta_kk)}}translog state-input quadratic coefficient; available
on non-grouped translog results only{p_end}
{synopt:{cmd:e(beta_lk)}}translog interaction coefficient; available on
non-grouped translog results only{p_end}
{p2colreset}{...}

{pstd}
{it:Matrices}

{synoptset 22 tabbed}{...}
{synopt:{cmd:e(rho_0)}}untreated evolution coefficients{p_end}
{synopt:{cmd:e(rho_by)}}grouped untreated evolution coefficients used by
{cmd:predict, residuals} after grouped estimation, including grouped bootstrap
public reposts when retained{p_end}
{synopt:{cmd:e(attperiods)}}1 x K row vector of exact integer ATT/TT event times
used by {cmd:predict, tt} and {cmd:predict, att}{p_end}
{synopt:{cmd:e(att)}}1 x (K+1) ATT vector; last column is pooled ATT{p_end}
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
{p2colreset}{...}

{pstd}
{it:Macros}

{synoptset 22 tabbed}{...}
{synopt:{cmd:e(cmd)}}{cmd:pte}{p_end}
{synopt:{cmd:e(PFtype)}}production-function type{p_end}
{synopt:{cmd:e(idvar)}}exact stored panel id used by residual fallback when
available{p_end}
{synopt:{cmd:e(timevar)}}exact stored time variable used by residual fallback
when available{p_end}
{synopt:{cmd:e(id)}}legacy stored panel id used as fallback by
{cmd:predict, residuals}{p_end}
{synopt:{cmd:e(time)}}legacy stored time variable used as fallback by
{cmd:predict, residuals}{p_end}
{synopt:{cmd:e(treatsig)}}live treatment-law signature used to certify
setup-backed {cmd:predict} calls; when present, it can certify the setup-backed
law even if {cmd:e(treatment)} is omitted, but pure-live {cmd:predict} now
requires the full {cmd:e(idvar)/e(timevar)/e(treatment)/e(treatsig)} bundle
before TT/ATT are mapped{p_end}
{synopt:{cmd:e(treatment)}}live treatment variable name checked against the
stored setup contract when present; omitted or dot-sentinel payloads are treated
as missing on the law-first certification path{p_end}
{synopt:{cmd:e(by)}}grouping variable used by grouped {cmd:predict, residuals}
and {cmd:predict, att}; grouped {cmd:predict, parameters} reports when grouped
labels remain stored in {cmd:e(groups)}{p_end}
{synopt:{cmd:e(groups)}}stored grouped-estimation labels used by grouped
{cmd:predict, residuals} and {cmd:predict, att}; grouped
{cmd:predict, parameters} keeps those labels in {cmd:e(groups)} instead of
reprinting the raw token list{p_end}
{p2colreset}{...}

{pstd}
For the full list of stored objects, run {cmd:ereturn list} after
{cmd:pte}.

{marker references}{...}
{title:References}

{phang}
Chen, Zhiyuan, Moyu Liao, and Karl Schurter. 2026. Identifying
Treatment Effects on Productivity: Theory with an Application to
Production Digitalization. {it:Working Paper}.

{phang}
Ackerberg, D. A., K. Caves, and G. Frazer. 2015. Identification
properties of recent production function estimators.
{it:Econometrica} 83(6): 2411-2451.

{marker alsosee}{...}
{title:Also see}

{psee}
Manual: {manlink R predict}

{psee}
{space 2}Help: {helpb pte}, {helpb pte_graph}, {helpb pte_diagnose},
{helpb xtset}
