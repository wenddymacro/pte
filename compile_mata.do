*! compile_mata.do
*! Compiles all PTE Mata source files into lpte.mlib library
*! Usage: stata -b do compile_mata.do
*! Output: ado/lpte.mlib

version 14.0
clear all
set matastrict off

// Display header
display as text ""
display as text "============================================================"
display as text "  PTE Mata Library Compilation"
display as text "============================================================"
display as text ""

// Set working directory to project root (run this script from pte-stata/)
local project_root "`c(pwd)'"
cd "`project_root'"

// Clear all user-defined Mata functions to start fresh
mata: mata clear

// ================================================================
// Step 1: Compile all .mata source files
// ================================================================
display as text "Step 1: Compiling Mata source files..."
display as text ""

// --- Core GMM files (must be compiled first) ---
display as text "  [1/10] pte_gmm_clk.mata (core GMM optimizer)"
do "mata/pte_gmm_clk.mata"

display as text "  [2/10] pte_gmm_matrices.mata (matrix construction)"
do "mata/pte_gmm_matrices.mata"

// --- Simulation files ---
display as text "  [3/10] pte_simulate.mata (path simulation)"
do "mata/pte_simulate.mata"

display as text "  [4/10] _pte_simulate_omega1.mata (omega1 simulation)"
do "mata/_pte_simulate_omega1.mata"

// --- Aggregation and testing ---
display as text "  [5/10] pte_ivw_aggregate.mata (IVW aggregation)"
do "mata/pte_ivw_aggregate.mata"

display as text "  [6/10] pte_hetero_qtest.mata (heterogeneity Q-test)"
do "mata/pte_hetero_qtest.mata"

// --- Comparison estimators ---
display as text "  [7/10] _pte_compare_endog_gmm.mata (endogenous GMM)"
do "mata/_pte_compare_endog_gmm.mata"

display as text "  [8/10] _pte_compare_expost_gmm.mata (expost GMM)"
do "mata/_pte_compare_expost_gmm.mata"

// --- Helper functions ---
display as text "  [9/10] _pte_mc_engine_helpers.mata (MC engine helpers)"
do "mata/_pte_mc_engine_helpers.mata"

display as text "  [10/10] _pte_bygroup_helpers.mata (bygroup helpers)"
do "mata/_pte_bygroup_helpers.mata"

// --- Visualization helpers ---
display as text "  [11/10] _pte_color_map.mata (color mapping)"
do "mata/_pte_color_map.mata"

// --- Bootstrap aggregation ---
display as text "  [12/10] _pte_cf_divergent_boot_agg.mata (CF boot aggregation)"
do "mata/_pte_cf_divergent_boot_agg.mata"

display as text ""
display as text "  All source files compiled successfully."
display as text ""

// ================================================================
// Step 2: List compiled functions
// ================================================================
display as text "Step 2: Listing compiled Mata functions..."
mata: mata describe

// ================================================================
// Step 3: Create .mlib library in ado/ directory
// ================================================================
display as text ""
display as text "Step 3: Creating lpte.mlib library..."
display as text ""

// Add ado/ to adopath so mata mlib add can find the created library
adopath + "ado"

// Remove existing mlib if present
capture erase "ado/lpte.mlib"

// Create the library and add all compiled functions
mata: mata mlib create lpte, dir("ado") replace
mata: mata mlib add lpte *(), complete

display as text ""
display as text "  lpte.mlib created successfully in ado/ directory."

// ================================================================
// Step 4: Verify
// ================================================================
display as text ""
display as text "Step 4: Verifying library contents..."
mata: mata mlib index
mata: mata describe, all

display as text ""
display as text "============================================================"
display as text "  Compilation complete: ado/lpte.mlib"
display as text "============================================================"
display as text ""

exit
