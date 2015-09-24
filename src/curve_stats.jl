function curve_karcher_mean(beta::Array{Float64, 3}, mode='O')
    n, T, N = size(beta)
    q = zeros(n, T, N);
    for ii = 1:N
        q[:,:,ii] = curve_to_q(beta[:,:,ii])
    end

    # Initialize mu as one of the shapes
    mu = q[:, :, 0];
    betamean = beta[:, :, 0];

    delta = 0.5;
    tolv = 1e-4;
    told = 5*1e-3;
    maxit = 20;
    itr = 1;
    sumd = zeros(maxit+1);
    v = zeros(n,T,N);
    mormvbar = zeros(maxit+1);

    while itr < maxit
        @printf("Iteration: %d\n", itr)

        mu /= sqrt(innerprod_q2(mu,mu));

        sumv = zeros(2, T);
        sumd[itr] = 0.;

        # TODO: parallelize

        for i = 1:N
            v1, d = karcher_calc(beta[:,:,n],q[:,:,n], betamean, mu, mode);
            v[:,:,i] = v1;
            sumd[itr+1] = sumd[itr+1] + d^2;
        end

        sumv = sum(v,3);

        # compute average direction of tangent vectors v_i
        vbar = sumv./float(N);

        normvbar[itr] = sqrt(innerprod_q2(vbar,vbar));
        normv = normvbar[itr];

        if (normv > tolv && abs(sumd[itr+1]-sumd[itr])>told)
            # update mu in direction of vbar
            mu = cos(delta*normvbar[itr])*mu + sin(delta*normvbar[itr]) *
                vbar/normvbar[itr];

            if mode == 'C'
                mu = project_curve(mu);
            end

            x = q_to_curve(mu);
            a = -1 * calculatecentroid(x);
            betamean = x + repat(a,1,T);
        else
            break
        end

        itr += 1;

    end

    return (mu, betamean, v, q)
end


function curve_srvf_align(beta::Array{Float64, 3}, mode='O')
    n, T, N = size(beta);
    # find mean
    mu, betamean, v, q = curve_karcher_mean(beta, mode=mode);

    qn = zeros(n,T,N);
    betan = zeros(n,T,N);
    centroid2 = calculatecentroid(betamean);
    betamean -= repmat(centroid2, 1, T);
    q_mu = curve_to_q(betamean);

    # align to mean
    for ii = 1:N
        beta1 = beta[:,:,ii];
        centroid1 = calculatecentroid(beta1);
        beta1 -= repamt(centroid1, 1, T);

        # Iteratively optimzie over SO(n) x Gamma
        # Optimize over SO(n) x Gamma
        gam, R, tau = optimum_reparam(betamean, beta1);
        gamI = invertGamma(gam);
        beta1 = R * shift_f(beta1, tau);

        # Applying optimal re-parameterization to the second curve
        beta1 = group_action_by_gamma_coord(beta1, gamI);

        # Optimize over SO(n)
        beta1, R, tau = find_rotation_and_seed_coord(betamean, beta1);
        qn[:,:,ii] = curve_to_q(beta1);
        betan[:,:,ii] = beta1;
    end

    return betan, qn, betamean, q_mu
end


function curve_karcher_cov(betamean::Array{Float64,2}, beta::Array{Float64,3},
                           mode='O')
    n, T, N = size(beta);

    # Compute Karcher covariance of uniformly sampled mean
    betamean = resamplecurve(betamean, T);
    mu = curve_to_q(betamean);
    if mode == 'C'
        mu = project_curve(mu);
        basis = find_basis_normal(mu);
    end

    v = zeros(n, T, N);
    for i = 1:N
        beta1 = beta[:, :, i];

        w, dist = inverse_exp_coord(betamean, beta1);
        # Project to the tangent space of manifold to obtain v_i
        if mode == 'O'
            v[:,:,i] = w;
        else
            v[:,:,i] = project_tangent(w, mu, basis);
        end
    end

    K = zeros(2*T, 2*T);

    for i = 1:N
        w = v[:,:,i];
        w = [w[1,:], w[2,:]];
        K = K + w'*w';
    end

    K /= (N-1);

    return K
end


function curve_principal_directions(betamean::Array{Float64, 2}, mu, K,
                                    mode='O', no=3, N=5)
    n, T = size(betamean);
    U, s, V = svd(K);

    qarray = Array(any, no, 2*N+1);
    qarray1 = Array(any, N);
    qarray2 = Array(any, N);
    pd = Array(any, no, 2*N+1);
    pd1 = Array(any, N);
    pd2 = Array(any, N);

    for m = 1:no
        princDir = [U[1:T,m]'; U[T+1:2*T,m]'];
        v = sqrt(s[m])*princDir;
        q1 = copy(mu);
        epsilon = 2./N;

        # Forward direction from mean
        for i = 1:N
            normv = sqrt(innerprod_q2(v,v));

            if normv < 1e-4
                q2 = copy(mu);
            else
                q2 = cos(epsilon*normv)*q1 + sin(epsilon*normv)*v/normv;
                if mode == 'C'
                    q2 = project_curve(q2);
                end
            end

            qarray1[i] = q2;
            p = q_to_curve(q2);
            centroid1 = -1 * calculatecentroid(p);
            beta_scaled, scale = scale_curve(p + repmat(centroid1,1, T));
            pd1[i] = beta_scaled;

            # Parallel translate tangent vector
            basis2 = find_basis_normal(q2);
            v = parallel_translate(v, q1, q2, basis2, mode);

            q1 = copy(q2);
        end

        # Backward direction from mean
        v = -sqrt(s[m])*princDir;
        q1 = mu;
        for i = 1:N
            normv = sqrt(innerprod_q2(v,v));

            if normv < 1e-4
                q2 = copy(mu);
            else
                q2 = cos(epsilon*normv)*q1 + sin(epsilon*normv)*v/normv;
                if mode == 'C'
                    q2 = project_curve(q2);
                end
            end

            qarray2[i] = q2;
            p = q_to_curve(q2);
            centroid1 = -1*calculatecentroid(p);
            beta_scaled, scale = scale_curve(p + repmat(centroid1, 1, T));
            pd2[i] = beta_scaled;

            # parallel translate tangent vector
            basis2 = find_basis_normal(q2);
            v = parallel_translate(v, q1, q2, basis2, mode);

            q1 = copy(q2);
        end

        for i = 1:N
            qarray[m,i] = qarray2[N+1-i];
            pd[m, i] = pd2[N+1-i];
        end

        qarray[m,N] = mu;
        centroid1 = -1 * calculatecentroid(betamean);
        beta_scaled, scale = scale_curve(betamean + repmat(centroid1,1, T));

        pd[m, N] = beta_scaled;

        for i = 1:N;
            qarray[m,i+N] = qarray1[i];
            pd[m,i+N] = pd1[i];
        end

    end

    return pd
end


function sample_shapes(mu::Array{Float64,2}, K, mode='O', no=3, numSamp=10)
    n, T = size(mu);

    U,s,V = svd(K);

    if mode == 'O'
        N = 2;
    else
        N = 10;
    end

    epsilon = 1./(N-1);

    samples = Array(any, numSamp);
    for i = 1:numSamp
        v = zeros(2,T);
        for m = 1:no
            v = v + randn()*sqrt(s[m])*[U[1:T,m]';U[T+1:2*T,m]'];
        end

        q1 = copy(mu);
        for j = 1:N-1
            normv = sqrt(innerprod_q2(v,v));

            if normv < 1e-4
                q2 = copy(mu);
            else
                q2 = cos(epsilon*normv)*q1 + sin(epsilon*normv)*v/normv;
                if mode == 'C'
                    q2 = project_curve(q2);
                end
            end

            # Parallel translate tangent vector
            basis2 = find_basis_normal(q2);
            v = parallel_translate(v, q1, q2, basis2, mode);

            q1 = copy(q2);
        end

        samples[i] = q_to_curve(q2);
    end

    return samples
end


function karcher_calc(beta, q, betamean, mu, mode='O')
    if mode == 'C'
        basis = find_basis_normal(mu);
    end
    # Compute shooting vector from mu to q_i
    w, d = inverse_exp_coord(betamean, beta);

    # Project to tangent space of mainfold to obtain v_i
    if mode == 'O'
        v = copy(w);
    else
        v = project_tangent(w, q, basis);
    end

    return v,d
end

