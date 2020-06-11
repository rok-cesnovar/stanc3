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
  profile_start("theta");
  theta ~ normal(mu, tau);
  profile_end("theta");
  
  profile_start("y");
  y ~ normal(theta,sigma);
  profile_end("y");
}
