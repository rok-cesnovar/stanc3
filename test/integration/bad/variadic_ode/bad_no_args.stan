functions {
  real[] dz_dt(real t,       // time
               real[] z) {     // system state {prey, predator}) {
    real u = z[1];
    real v = z[2];
   
    real du_dt = v * u;
    real dv_dt = u * v;
   
    return { du_dt, dv_dt };
  }
}
data {
  int<lower = 0> N;          // number of measurement times
  real ts[N];                // measurement times > 0
  real y_init[2];            // initial measured populations
  real<lower = 0> y[N, 2];   // measured populations
}
parameters {
  real<lower = 0> z_init[2];  // initial population
  real<lower = 0> sigma[2];   // measurement errors
}
transformed parameters {
  real z[N, 2]
  = ode_bdf_tol(dz_dt, z_init, 0.0, ts,
            1e-5, 1e-3, 500);
}
model {
}
