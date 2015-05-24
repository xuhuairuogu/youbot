function [E, T_noise_squared, d] = error_cylinder(Theta, X, sigma, P_inlier, parameters)

% [E T_noise_squared d] = error_circle(Theta, X, sigma, P_inlier, parameters)
%
% DESC:
% Estimate the error due to the circle constraint. To
% return only the error threshold the function call should be:
%
% [dummy T_noise d] = error_foo([], [], sigma, P_inlier, parameters);
%
% INPUT:
% Theta             = the parameter vector
% X                 = samples on the manifold
% sigma             = noise std
% P_inlier          = Chi squared probability threshold for inliers
%                     If 0 then use directly sigma.
% parameters        = parameters.radius is the radius of the circle
%
% OUTPUT:
% E                 = squared error
% T_noise_squared   = squared noise threshold
% d                 = degrees of freedom of the error distribution

% compute the error obtained by the orthogonal projection of
% the data points X onto the model manifold instantiated with the
% parameters Theta
E = [];
if ~isempty(Theta) && ~isempty(X)

    % error computation
    xc = Theta(1);
    yc = Theta(2);
    zc = Theta(3);
    r = Theta(4);
    v = [Theta(5) Theta(6) Theta(7)];
    cyl_axe = [xc yc zc v(1) v(2) v(3)];
    l = length(X(1,:));
    E = zeros(1, l);
    
    for i=1:l
        dist_pt_axe = distancePointLine3d(X(:,i)', cyl_axe);
        E(i) = abs(dist_pt_axe - r);
    end
end;

% compute the error threshold
if (nargout > 1)

    if (P_inlier == 0)
        % in this case the parameter sigma coincides with the noise
        % threshold
        T_noise_squared = sigma;
    else
        % otherwise we compute the error threshold given the standard
        % deviation of the noise assuming that the errors are normally
        % distributed. Hence the sum of their squares is Chi2
        % distributed with d degrees of freedom
        d = 2;

        % compute the inverse probability
        T_noise_squared = sigma^2 * chi2inv_LUT(P_inlier, d);

    end;

end;

return;

