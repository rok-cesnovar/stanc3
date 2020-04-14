functions {
  real my_func(int start, int end, real[] y_slice, real mu, real sigma) {
    return normal_lpdf(y_slice | mu, sigma);
  }  
}

parameters {
  real a;
}

model {
  target += reduce_sum_static(my_func, a, 1, 0.0);
}