data {
  int<lower=0> J;          // number of schools
  real y[J];               // estimated treatment effect (school j)
  real<lower=0> sigma[J];  // std err of effect estimate (school j)
}
parameters {
  real mu;
  real theta[J];
  real<lower=0> tau;
}
model {
  start_profiling("theta");
  theta ~ normal(mu, tau);
  stop_profiling("theta");
  
  start_profiling("y");
  y ~ normal(theta,sigma);
  stop_profiling("y");
}
