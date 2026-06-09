use "/Users/cxy/Desktop/2026project/pte/pte-stata/data/manuf_est_data.dta", clear
gen w = log(wage_all/labor)
drop if w == .
winsor2 lnk lny lnl w, replace cuts(1 99) trim
drop if lnk == . | lny == . | lnl == .
gen Ind1_str = substr(IndcodeA, 2, 1)
destring Ind1_str, gen(Ind1_num)
drop if Ind1_num == 1 | Ind1_num == 2 | Ind1_num == 9
egen indid_adj = group(Ind1_num)
gen post = (year >= treat_yr0)
gen treat_post = treat * post
tab indid_adj treat_post
bysort indid_adj: egen n_treated = total(treat_post)
tab indid_adj, summarize(n_treated)
