function youbot_B1D2(map2)
% This function controls the youbot to create a map of the
% environnement where it will evolve, and then to pick up objects on tables
% and put them into the appropriate baskests according to the given
% instructions. In the current state of this work, coordinates of the tables
% and baskets are considered known, and the robot is only capable of
% picking up objects that are vertically standing and well separated from one
% another.

disp('Program started');
%Use the following line if you had to recompile remoteApi
%vrep = remApi('remoteApi', 'extApi.h');
vrep=remApi('remoteApi');
vrep.simxFinish(-1);
id = vrep.simxStart('127.0.0.1', 19997, true, true, 2000, 5);

if id < 0,
    disp('Failed connecting to remote API server. Exiting.');
    vrep.delete();
    return;
end
fprintf('Connection %d to remote API server open.\n', id);

% Make sure we close the connexion whenever the script is interrupted.
cleanupObj = onCleanup(@() cleanup_vrep(vrep, id));

% This will only work in "continuous remote API server service"
% See http://www.v-rep.eu/helpFiles/en/remoteApiServerSide.htm
res = vrep.simxStartSimulation(id, vrep.simx_opmode_oneshot_wait);
% We're not checking the error code - if vrep is not run in continuous remote
% mode, simxStartSimulation could return an error.
% vrchk(vrep, res);

% Retrieve all handles, and stream arm and wheel joints, the robot's pose,
% the Hokuyo, and the arm tip pose.
h = youbot_init(vrep, id);
h = youbot_hokuyo_init(vrep, h);

% Let a few cycles pass to make sure there's a value waiting for us next time
% we try to get a joint angle or the robot pose with the simx_opmode_buffer
% option.
pause(.2);

% Constants:
timestep = .05;
d = 7.5; % distance between the reference frame and a frame in the corner of the map
cell_size = 0.25; % size of the side of a cell in the grid representing the map
d_star = 0.2; % The robot maintains this distance behind a pursuit point
c_box = 0.05; % length of the side of a box_shaped object
d_cyl = 0.05; % diameter of a cylinder object
d_table = 0.8; % diameter of the tables and baskets
h_table = 0.185; % height of tables and baskests
d_basket = d_table;
h_basket = h_table;
r_table_traj = d_table/2+0.25; % radius of a circular trajectory around a table/basket
n_table_traj = 200; % number of points that constitutes the previous trajectory
r_table_zone = d_table/2+0.4; % radius of circle delimiting a zone where the robot is considered near the table/basket
n_table_zone = 15; % number of points that constitutes the previous circle

% Position of the camera in the reference frame of the youbot
[res, rgbdPos] = vrep.simxGetObjectPosition(id, h.rgbdCasing, h.ref,...
    vrep.simx_opmode_oneshot_wait);
vrchk(vrep, res, true);

% Min max angles for all joints:
armJointRanges = [-2.9496064186096,2.9496064186096;
    -1.5707963705063,1.308996796608;
    -2.2863812446594,2.2863812446594;
    -1.7802357673645,1.7802357673645;
    -1.5707963705063,1.5707963705063 ];

% arm configurations
startingJoints = [0,30.91*pi/180,52.42*pi/180,72.68*pi/180,0];
transportJoints = [0,30.91*pi/180,52.42*pi/180,0*pi/180,0];
throwJoints = [90*pi/180, 19.6*pi/180, 113*pi/180, -41*pi/180, 0*pi/180];

% Parameters for controlling the youBot's wheels:
forwBackVel = 0;
leftRightVel = 0;
rotVel = 0;

% table positions (TEMPORARY, tables will be detected during map exploration)
table1 = [-3 -6];
table1_traj = circle(table1, r_table_traj, 'n', n_table_traj);
table1_zone = circle(table1, r_table_zone, 'n', n_table_zone);

% instructions (TEMPORARY)
inst = struct('shape', 'box', 'pose', [-3.275; -6.15; 0.2151], 'dest', [-1 0]);
inst(1).basket_zone = circle(inst(1).dest, r_table_zone, 'n', n_table_zone);
inst(1).basket_traj = circle(inst(1).dest, r_table_traj, 'n', n_table_traj);
inst(1).colorname = 'green';
inst(2).shape = 'cylinder';
inst(2).pose = [-3.35; -5.92; 0.2151];
inst(2).dest = [-7 -3]; %dog
inst(2).basket_zone = circle(inst(2).dest, r_table_zone, 'n', n_table_zone);
inst(2).basket_traj = circle(inst(2).dest, r_table_traj, 'n', n_table_traj);
inst(2).colorname = 'blue';
inst(3).shape = 'cylinder';
inst(3).pose = [-3.2; -5.725; 0.2351];
inst(3).dest = [7 7]; %pumpkin
inst(3).basket_zone = circle(inst(3).dest, r_table_zone, 'n', n_table_zone);
inst(3).basket_traj = circle(inst(3).dest, r_table_traj, 'n', n_table_traj);
inst(3).colorname = 'red';
inst(4).shape = 'box';
inst(4).pose = [-3; -5.65; 0.2451];
inst(4).dest = [-7 7]; %trike
inst(4).basket_zone = circle(inst(4).dest, r_table_zone, 'n', n_table_zone);
inst(4).basket_traj = circle(inst(4).dest, r_table_traj, 'n', n_table_traj);
inst(4).colorname = 'yellow';
inst(5).shape = 'box';
inst(5).pose = [-2.75; -5.8; 0.2151];
inst(5).dest = [7 3]; %plant
inst(5).basket_zone = circle(inst(5).dest, r_table_zone, 'n', n_table_zone);
inst(5).basket_traj = circle(inst(5).dest, r_table_traj, 'n', n_table_traj);
inst(5).colorname = 'red';

% set RANSAC options
cyl_options.epsilon = 1e-6;
cyl_options.P_inlier = 0.9999;
cyl_options.est_fun = @estimate_circle;
cyl_options.man_fun = @error_circle;
cyl_options.mode = 'MSAC';
cyl_options.Ps = [];
cyl_options.notify_iters = [];
cyl_options.min_iters = 100;
cyl_options.fix_seed = false;
cyl_options.reestimate = true;
cyl_options.stabilize = false;
cyl_options.parameters.radius = d_cyl/2-0.0025;
cyl_options.T_noise_squared = 0.0002;

% Flags
fsm = 'go to table/basket';
initialRotation = true;
needNewTraject = true;
explorationComplete = false;
startRound = true;
startGoing = true;
objectPickedUp = false;
objectIdentified = false;
objectLocated = false;

% initialization of some variables
prev_e = 0.5;
traj_indices = [-1, -1];
fill_point = [-1 -1];
searching_counter = 0;
box_nb = 1;
goal = table1;

% initialisation of the map
[X,Y] = meshgrid(-5:cell_size:5,-5.5:cell_size:2.5);
X = reshape(X, 1, []);
Y = reshape(Y, 1, []);
colormap([0 104/255 139/255; 0 1 127/255; 205/255 38/255 38/255; 0 0 0; 1 0.5 0]);
map = zeros((d/cell_size)*2); map(:) = -1;


disp('Starting robot');

% Set the arm to its starting configuration:
res = vrep.simxPauseCommunication(id, true); vrchk(vrep, res);
for i = 1:5,
    res = vrep.simxSetJointTargetPosition(id, h.armJoints(i),...
        startingJoints(i),...
        vrep.simx_opmode_oneshot);
    vrchk(vrep, res, true);
end
res = vrep.simxPauseCommunication(id, false); vrchk(vrep, res);

% Make sure everything is settled before we start
pause(2);

traj_timer = tic;

while true,
    sim_timer = tic;
    if vrep.simxGetConnectionId(id) == -1,
        error('Lost connection to remote API.');
    end
    
    % Get the youbot position and orientation at every iteration
    [res, youbotPos] = vrep.simxGetObjectPosition(id, h.ref, -1,...
        vrep.simx_opmode_buffer);
    vrchk(vrep, res, true);
    [res, youbotEuler] = vrep.simxGetObjectOrientation(id, h.ref, -1,...
        vrep.simx_opmode_buffer);
    vrchk(vrep, res, true);
    
    if strcmp(fsm, 'exploration')
        
        % Get the data from the Hokuyo sensors
        [pts, contacts] = youbot_hokuyo(vrep, h, vrep.simx_opmode_buffer);
        in = inpolygon(X, Y, [h.hokuyo1Pos(1) pts(1,:) h.hokuyo2Pos(1)],...
            [h.hokuyo1Pos(2) pts(2,:) h.hokuyo2Pos(2)]);
        
        
        pose = [youbotPos(1) youbotPos(2) youbotEuler(3)];
        
        % a and b are the indices corresponding to the youbot position on
        % the map
        a = floor((pose(1)+d)/cell_size)+1;
        b = floor((pose(2)+d)/cell_size)+1;
        
        % Define the starting position of the youbot as the point where the
        % floodfill operations will start from. (For more information about
        % these floodfill operation, check in the "planNextMove" function)
        if(fill_point(1) == -1)
            fill_point = [a b];
        end
        
        % Mark the robot's position as observed
        if map(a, b) ~= 1
            map(a, b) = 0;
        end
        if map(a+1, b) ~= 1
            map(a+1, b) = 0;
        end
        if map(a, b+1) ~= 1
            map(a, b+1) = 0;
        end
        if map(a+1, b+1) ~= 1
            map(a+1, b+1) = 0;
        end
        if map(a+1, b-1) ~= 1
            map(a+1, b-1) = 0;
        end
        if map(a-1, b+1) ~= 1
            map(a-1, b+1) = 0;
        end
        if map(a-1, b-1) ~= 1
            map(a-1, b-1) = 0;
        end
        if map(a-1, b) ~= 1
            map(a-1, b) = 0;
        end
        if map(a, b-1) ~= 1
            map(a, b-1) = 0;
        end
        
        % update the map
        map = ptsToCellmap(X(in), Y(in), pts(1,contacts), pts(2,contacts), map,...
            cell_size,pose,d,true);
        
        % Display the map along with the youbot position and trajectory
        trajmap = map;
        if traj_indices(1) ~= -1
            trajmap(sub2ind(size(map),traj_indices(:,1),traj_indices(:,2))) = 2;
        end
        trajmap(a,b) = 3;
        imagesc(trajmap);
        drawnow;
        
        if initialRotation % Complete rotation at start
            rotVel = 5;
            if toc(traj_timer) > 6,
                rotVel = 0;
                initialRotation = false;
            end
            
        else % The rotation at start has been performed
            
            if needNewTraject % Destination reached -> Need to plan the next move
                [traj, map, traj_indices] = planNextMove(map, pose, d, cell_size, fill_point);
                
                if isempty(traj) % the environnement has been completely explored
                    fsm = 'go to table/basket';
                    explorationComplete = true;
                    figure
                    imagesc(map);
                    drawnow;
                else
                    s = size(traj);
                    if s(1) > 1
                        % adds more intermediate points to smooth the trajectory
                        traj = smooth_traj(traj); 
                        s = size(traj);
                    end
                    index = 1;
                    
                    needNewTraject = false;
                    traj_timer = tic;
                    prev_t = 0;
                    prev_e = 0.4;
                end
            end
            
            if not(explorationComplete)
                trajmap = map;
                trajmap(sub2ind(size(map),traj_indices(:,1),traj_indices(:,2))) = 2;
                trajmap(a,b) = 3;
                imagesc(trajmap);
                drawnow;
                 
                x = pose(1);
                y = pose(2);
                theta = pose(3);
                
                % Setting the intermediate destination (point of the trajectory)
                x_star = traj(index,1);
                y_star = traj(index,2);
                theta_star = atan2((y_star - y),(x_star - x))+pi/2;
                
                % Check if we are not running to an obstacle
                i_star = floor((x_star+d)/cell_size)+1;
                j_star = floor((y_star+d)/cell_size)+1;
                if index == s(1) || map(i_star,j_star) == 1
                    needNewTraject = true;
                end
                
                % Control the youbot velocity, direction and trajectory
                t = toc(traj_timer);
                e = sqrt((x_star-x)^2+(y_star-y)^2)-d_star;
                if e > 0.01 % intermediate destination not reached yet
                    v_star = 20*e + 30*(abs(t-prev_t)*abs(e-prev_e)/2);
                    alpha = angdiff(theta_star, theta);
                    gamma = -theta+atan2((y_star - y),(x_star - x));
                    forwBackVel = v_star*sin(gamma);
                    leftRightVel = v_star*cos(gamma);
                    rotVel = alpha*(abs(forwBackVel)+abs(leftRightVel))/2;    
                else
                    index = index + 1;
                    if index == s(1) % Final destination reached
                        needNewTraject = true;
                        forwBackVel = 0;
                        leftRightVel = 0;
                        rotVel = 0;
                    end
                end
            end
        end
        
    elseif strcmp(fsm, 'go to table/basket')
        
        if objectPickedUp % need to go to the appropriate basket
            circle_zone = inst(box_nb).basket_zone;
        else % need to go to the table
            circle_zone = table1_zone;
        end
        
        if startGoing
            % Set the destination of the youbot to the closest point of the
            % circle delimiting the zone near the table/basket
            zone_index = find_closest_point(circle_zone, youbotPos(1), youbotPos(2));
            
            % Sometimes the chosen destination is an obstacle on the map
            % representation (because of its limited precision), and in
            % that case we just look further on the circle for another 
            % point until its not considered as an obstacle
            destIsObstacle = true;
            while destIsObstacle
                destIsObstacle = false;
                try
                    dest = [circle_zone(1,zone_index) circle_zone(2,zone_index)];
                    traj = calc_traj(map2, youbotPos, dest, cell_size, d);
                catch
                    destIsObstacle = true;
                    if zone_index == n_table_zone
                        zone_index = 1;
                    else
                        zone_index = zone_index+1;
                    end
                end
            end
            
            s = size(traj);
            traj = [traj; dest];
            if s(1) > 1
                traj = smooth_traj(traj);
                s = size(traj);
            end
            index = 1;
            traj_timer = tic;
            prev_t = 0;
            prev_e = 0.4;
            startGoing = false;
        end
        
        x = youbotPos(1);
        y = youbotPos(2);
        theta = youbotEuler(3);
        
        x_star = traj(index,1);
        y_star = traj(index,2);
        theta_star = atan2((y_star - y),(x_star - x))+pi/2;
        
        t = toc(traj_timer);
        e = sqrt((x_star-x)^2+(y_star-y)^2)-d_star;
        if e > 0.01
            v_star = 20*e + 30*(abs(t-prev_t)*abs(e-prev_e)/2);
            alpha = angdiff(theta_star, theta);
            gamma = -theta+atan2((y_star - y),(x_star - x));
            forwBackVel = v_star*sin(gamma);
            leftRightVel = v_star*cos(gamma);
            rotVel = alpha*(abs(forwBackVel)+abs(leftRightVel))/2;
            
        else
            index = index + 1;
            if index > s(1)
                fsm = 'get close table/basket';
                startGetClose = true;
                forwBackVel = 0;
                leftRightVel = 0;
                rotVel = 0;
            end
        end
        
    elseif strcmp(fsm, 'get close table/basket')
        
        if startGetClose
            theta_star = table_tg_angle(goal, youbotPos(1:2));
            startGetClose = false;
            rotation_performed = false;
        end
        
        % First turn the robot to make its direction tangent to the table/basket, 
        % and clockwise oriented
        if not(rotation_performed)
            angdif = angdiff(theta_star, youbotEuler(3));
            rotVel = 10*angdif;
            if abs(angdif) < 1/180*pi,
                rotVel = 0;
                rotation_performed = true;
            end
        else % Then get close to the table/basket using the left-right velocity
            e = sqrt((goal(1)-youbotPos(1))^2+(goal(2)-youbotPos(2))^2);
            leftRightVel = 10*e;
            
            if e <= 0.25+d_table/2
                leftRightVel = 0;
                
                if objectPickedUp
                    fsm = 'throw';
                else
                    fsm = 'find closest box';
                    startRound = true;
                end
            end
        end
        
    elseif strcmp(fsm, 'find closest box')
        
        res = vrep.simxSetFloatSignal(id, 'rgbd_sensor_scan_angle', pi/2,...
            vrep.simx_opmode_oneshot_wait);
        vrchk(vrep, res);
        
        cam_angle = pi/7;
        
        vrep.simxSetObjectOrientation(id, h.rgbdCasing, h.ref,...
            [0 0 cam_angle], vrep.simx_opmode_oneshot);
        
        % Take a single 3D image of the table, with a large angle of view,
        % to detect objects on the table
        res = vrep.simxSetIntegerSignal(id, 'handle_xyz_sensor', 1,...
            vrep.simx_opmode_oneshot_wait);
        vrchk(vrep, res);
        
        fprintf('Capturing point cloud...\n');
        ptsCloud = youbot_xyz_sensor(vrep, h, vrep.simx_opmode_oneshot_wait);
        
        % Here, we only keep points above the table
        ptsCloud = ptsCloud(1:4, ptsCloud(4,:) < d_table+0.3);
        ptsCloud = ptsCloud(1:4, ptsCloud(2,:) > -0.015);
        [box_pose, dist] = closest_point_from_cloud(ptsCloud);
        
        figure
        plot3(ptsCloud(3,:),ptsCloud(1,:),ptsCloud(2,:), '*')
        
        if isempty(box_pose)
            % Need to check if there is still objects on the table that the
            % sensor didn't see because of its view angle.
            % To do that we set a destination point a little further
            % on the trajectory around the table, from where the robot will
            % try again to find an object.
            
            % counts the number of times the robot has gone further because
            % he didn't found any object from  its point of view
            searching_counter = searching_counter +1;
            
            if searching_counter == 6
                % the robot has made a complete turn around the table 
                %  without finding anything --> his job is done.
                pause(1);
                break
            end
            
            % The destination where the robot will take another look on
            % the table is set in box_pose, since this variable is
            % used as destination when the robot is turning around the
            % table.
            % First we calculate the coordinates in the reference frame of
            % the robot.
            box_pose(1) = sqrt((table1(1)-youbotPos(1))^2+(table1(2)-youbotPos(2))^2)-0.5*d_table*cos(pi/4);
            box_pose(2) = 0.5*d_table*sin(pi/4);
            
            box_pose = [box_pose(1); box_pose(2); 0.2];
            
            % Then convert the coordinates from the frame of the youbot to the
            % main frame
            T = se2(youbotPos(1), youbotPos(2), youbotEuler(3));
            box_pose(1:2) = homtrans(T,box_pose(1:2));
            
        else
            % Convert box coordinates from the frame of the cam to the
            % frame of the youbot
            T = se2(rgbdPos(1),rgbdPos(2),cam_angle);
            box_pose(1:2) = homtrans(T,box_pose(1:2));
            
            % Convert box coordinates from the frame of the youbot to the
            % main frame
            T = se2(youbotPos(1), youbotPos(2), youbotEuler(3));
            box_pose(1:2) = homtrans(T,box_pose(1:2));
            
            % Reset the counter and raise the flag telling an object has
            % been located
            searching_counter = 0;
            objectLocated = true;
        end
        
        startRound = true;
        fsm = 'round';
        
    elseif strcmp(fsm, 'round') % the youbot turn around a table
        
        % Select the youbot component which needs to reach the
        % destination. It is either the arm reference if a box has been
        % identified and localized, either the camera, if we want the
        % youbot to go near an object to analyse it
        if objectIdentified
            [res, armPos] = vrep.simxGetObjectPosition(id, h.armRef, -1,...
                vrep.simx_opmode_oneshot_wait);
            vrchk(vrep, res, true);
            
            refPos = armPos;
        else
            T = se2(youbotPos(1), youbotPos(2), youbotEuler(3));
            p = [rgbdPos(1);rgbdPos(2)];
            refPos = homtrans(T,p);
        end
        
        x = youbotPos(1);
        y = youbotPos(2);
        theta = youbotEuler(3);
        
        if startRound
            circle_traj = table1_traj;
            
            % Set the index of the first point in the trajectory around the
            % table
            index = find_closest_point(circle_traj, x, y) + 4;
            if index > n_table_traj
                index = mod(index, n_table_traj);
            end
            
            startRound = false;
            traj_timer = tic;
            prev_e = 0.1;
            prev_t = 0;
            v_supp = 0;
            
            x_box = box_pose(1);
            y_box = box_pose(2);
            
            % Set the index of the destination point on the trajectory 
            % around the table
            index_dest = find_closest_point(circle_traj, x_box, y_box);
            x_dest = circle_traj(1,index_dest);
            y_dest = circle_traj(2,index_dest);
            
            % Choose the gyratory direction for the shortest path
            if (index_dest > index && index_dest - index < n_table_traj/2)...
                    || (index_dest < index && index - index_dest > n_table_traj/2)
                
                direction = -1;
            else
                direction = 1;
            end
            
            x_start = refPos(1);
            y_start = refPos(2);
            % Calculate the initial distance to be travelled before reaching the destination 
            dist_init_ref_dest = arc_dist(circle_traj, r_table_traj, [refPos(1); refPos(2)],[x_dest; y_dest]);;
        end
        
        x_star = circle_traj(1,index);
        y_star = circle_traj(2,index);
        if direction == 1
            theta_star = atan2((y_star - y),(x_star - x))-pi/2;
        else
            theta_star = atan2((y_star - y),(x_star - x))+pi/2;
        end
        
        t = toc(traj_timer);
        e = sqrt((x_star-x)^2+(y_star-y)^2)-0.1;
        if e > 0.01
            if v_supp < 0.8
                % Bound the velocity to be sure the robot won't deviate too
                % much from his circular trajectory
                v_supp = (abs(t-prev_t)*abs(e-prev_e)/2);
            end
            v_star = 25*e + 10*v_supp + 2;
            alpha = 15*angdiff(theta_star, theta);
            forwBackVel = direction*v_star;
            rotVel = alpha;
            
        else
            if direction == 1
                if index == 1
                    index = length(circle_traj(1,:));
                else
                    index = index -1;
                end
            else
                if index == length(circle_traj(1,:))
                    index = 1;
                else
                    index = index +1;
                end
            end
            
            % Calculates the traveled distance
            dist_traveled = arc_dist(circle_traj, r_table_traj,...
                [refPos(1); refPos(2)],[x_start; y_start]);
            
            % Calculates the progression
            prog = dist_traveled/dist_init_ref_dest;
            
            % The progression to the destination is completed when it reaches 1
            if prog >= 0.999
                
                if objectIdentified
                    fsm = 'grab';
                    objectIdentified = false;
                else
                    if objectLocated
                        fsm = 'identify object';
                        objectLocated = false;
                    else
                        fsm = 'find closest box';
                    end
                end
                forwBackVel = 0;
                leftRightVel = 0;
                rotVel = 0;
            end
        end
        
    elseif strcmp(fsm, 'identify object')
        
        % Reduce the view angle to better see the objects
        res = vrep.simxSetFloatSignal(id, 'rgbd_sensor_scan_angle', pi/8,...
            vrep.simx_opmode_oneshot_wait);
        vrchk(vrep, res);
        
        % Find the angle to orient the camera towards the center of the table
        T = se2(youbotPos(1), youbotPos(2), youbotEuler(3));
        camPos = [rgbdPos(1);rgbdPos(2)];
        camPos = homtrans(T,camPos);
        p = [rgbdPos(1)+1;rgbdPos(2)];
        p = homtrans(T,p);
        cam_angle = angle_3pts(camPos, table1, p);
        
        vrep.simxSetObjectOrientation(id, h.rgbdCasing, h.ref,...
            [0 0 cam_angle], vrep.simx_opmode_oneshot);
        
        % Take a single 3D image of the object
        res = vrep.simxSetIntegerSignal(id, 'handle_xyz_sensor', 1,...
            vrep.simx_opmode_oneshot_wait);
        vrchk(vrep, res);
        fprintf('Capturing point cloud...\n');
        ptsCloud = youbot_xyz_sensor(vrep, h, vrep.simx_opmode_oneshot_wait);
        
        % Here we (try to) keep the points belonging to a single object
        ptsCloud = ptsCloud(1:4, ptsCloud(2,:) > -0.02);
        [box_pose, dist] = closest_point_from_cloud(ptsCloud);
        ptsCloud = ptsCloud(1:4, ptsCloud(4,:) < dist+0.15);
        
        figure
        plot3(ptsCloud(3,:),ptsCloud(1,:),ptsCloud(2,:), '*')
        
        % Project the points cloud on the plane of the table
        pts = [ptsCloud(3,:); ptsCloud(1,:)];
        n_pts = length(pts(1,:));
        
        figure;
        plot(pts(1,:),pts(2,:),'*')
        
        % Use of RANSAC circle detection on the projected points to determine 
        % if the object is cylindrical or box-shaped.
        [results, options_res] = RANSAC(pts, cyl_options);
        
        if sum(results.CS)/n_pts >= 0.9
            shape = 'cylinder'
            box_pose = [results.Theta(1);...
                results.Theta(2);...
                (max(ptsCloud(2,:))+min(ptsCloud(2,:)))/2-0.005];
            d_further = d_cyl/2.5;
        else
            shape  = 'box'
%             if sum(results.CS)/n_pts > 0.2
%                 % RANSAC fitted a circle on some of the box point, so the
%                 % center of this circle is very likely close to the one of
%                 % the box
%                 box_pose = [results.Theta(1);...
%                     results.Theta(2);...
%                     (max(ptsCloud(2,:))+min(ptsCloud(2,:)))/2];
%                 d_further = d_cyl/2;
%             else
                % Approximate the center of the box
                box_pose = [(max(ptsCloud(3,:))+min(ptsCloud(3,:)))/2;...
                    (max(ptsCloud(1,:))+min(ptsCloud(1,:)))/2;...
                    (max(ptsCloud(2,:))+min(ptsCloud(2,:)))/2];
                d_further = d_cyl/2.5;
%             end
        end
        
        if isequal(size(box_pose), [3 1])
            % Convert the object coordinates from the frame of the cam to the
            % frame of the youbot
            T = se2(rgbdPos(1),rgbdPos(2),cam_angle);
            box_pose(1:2) = homtrans(T,box_pose(1:2));
            
            % Convert box coordinates from the frame of the youbot to the
            % main frame
            T = se2(youbotPos(1), youbotPos(2), youbotEuler(3));
            box_pose(1:2) = homtrans(T,box_pose(1:2));
            box_pose(3) = box_pose(3)+0.12;
            
            objectIdentified = true;
            fsm = 'round';
            startRound = true;
        else
            fsm = 'find closest box';
            objectLocated = false;
        end
        
    elseif strcmp(fsm, 'grab')
        
        [res, armPos] = vrep.simxGetObjectPosition(id, h.armRef, -1,...
            vrep.simx_opmode_oneshot_wait);
        vrchk(vrep, res, true);
        [res, armEuler] = vrep.simxGetObjectOrientation(id, h.armRef, -1,...
            vrep.simx_opmode_oneshot_wait);
        vrchk(vrep, res, true);
        
        % Express the object coordinates in the frame of the youbot arm
        T = se2(armPos(1), armPos(2), armEuler(3));
        p = box_pose;
        p(3) = p(3)+ 0.1;
        p(1:2) = homtrans(inv(T), p(1:2));
        
        % Calculate the tip trajectory  
        tipTraj = calc_tip_traj(p, 1.2*d_cyl, d_further, 50);
        index = 1;
        
        % Setting the arm to the starting position  of the trajectory
        p = tipTraj(:,index);
        vrep.simxSetIntegerSignal(id, 'km_mode', 1, vrep.simx_opmode_oneshot_wait);
        vrchk(vrep, res, true);
        vrep.simxSetObjectPosition(id, h.ptarget, h.armRef, p,...
            vrep.simx_opmode_oneshot_wait);
        
        % Wait for the arm to be in the starting position 
        gripTargDist = 1;
        while gripTargDist > 0.0005
            [res, tipPos] = vrep.simxGetObjectPosition(id, h.ptip, h.armRef,...
                vrep.simx_opmode_oneshot_wait);
            vrchk(vrep, res, true);
            gripTargDist = sqrt((p(1)-tipPos(1))^2+(p(2)-tipPos(2))^2);
        end
        
        % Make the arm follow the trajectory defined previously
        while index <= length(tipTraj(1,:))
            p = tipTraj(:,index);
            vrep.simxSetObjectPosition(id, h.ptarget, h.armRef, p,...
                vrep.simx_opmode_oneshot_wait);
            pause(4/50);
            index = index+1;
        end
        
        % Grab the object by closing the gripper
        vrep.simxSetIntegerSignal(id, 'gripper_open', 0, vrep.simx_opmode_oneshot);
        vrchk(vrep, res, true);
        pause(2);
        
        % Set the arm to a predifined position to take a picture of the
        % object
        vrep.simxSetIntegerSignal(id, 'km_mode', 1, vrep.simx_opmode_oneshot_wait);
        vrchk(vrep, res, true);
        p =[0; -0.1-0.1662; p(3)];
        vrep.simxSetObjectPosition(id, h.ptarget, h.armRef,...
            p,...
            vrep.simx_opmode_oneshot_wait);
        gripTargDist = 1;
        while gripTargDist > 0.0005
            [res, tipPos] = vrep.simxGetObjectPosition(id, h.ptip, h.armRef,...
                vrep.simx_opmode_oneshot_wait);
            vrchk(vrep, res, true);
            gripTargDist = sqrt((p(1)-tipPos(1))^2+(p(2)-tipPos(2))^2);
        end
        
        pause(1);
        
        % Set the camera angle that look towards the arm of the youbot, and
        % so towards the object in its gripper
        cam_angle = pi/2;
        vrep.simxSetObjectOrientation(id, h.rgbdCasing, h.ref,...
            [0 0 cam_angle], vrep.simx_opmode_oneshot);
        % Reduce the view angle to focus on the object
        res = vrep.simxSetFloatSignal(id, 'rgbd_sensor_scan_angle', pi/10,...
            vrep.simx_opmode_oneshot_wait);
        % Read data from the RGB camera
        res = vrep.simxSetIntegerSignal(id, 'handle_rgb_sensor', 1,...
            vrep.simx_opmode_oneshot_wait);
        vrchk(vrep, res);
        fprintf('Capturing image...\n');
        [res resolution shot] = ...
            vrep.simxGetVisionSensorImage2(id, h.rgbSensor, 0,...
            vrep.simx_opmode_oneshot_wait);
        vrchk(vrep, res);
        fprintf('Captured %i pixels.\n', resolution(1)*resolution(2));
%         figure
%         imshow(shot);
%         drawnow;
        
        vrchk(vrep, res, true);
        
        % Find the color of the grabbed object
        color = get_object_color(shot)
        
        vrep.simxSetIntegerSignal(id, 'km_mode', 0, vrep.simx_opmode_oneshot_wait);
        vrchk(vrep, res, true);
        
        % Find the corresponding object in the instructions table
        box_nb = 0;
        for i = 1:length(inst)
            if strcmp(inst(i).shape, shape) &&...
                    strcmp(inst(i).colorname, color)
                box_nb = i;
            end
        end
        
        if box_nb ~= 0 % Matched object
            
            % Set the arm to its transport configuration and go to the
            % appropriate basket to throw  the object
            for i = 1:5
                res = vrep.simxSetJointTargetPosition(id, h.armJoints(6-i),...
                    transportJoints(6-i),...
                    vrep.simx_opmode_oneshot_wait);
                pause(1);
                vrchk(vrep, res, true);
            end
            pause(1);
            
            objectPickedUp = true;
            goal = inst(box_nb).dest;
            startGoing = true;
            fsm = 'go to table/basket';
            
        else % No corresponding object found -> the youbot failed to grab something
             % -> set the arm to its starting position and look again for
             % an object to grab
            objectPickedUp = false;
            vrep.simxSetIntegerSignal(id, 'gripper_open', 1, vrep.simx_opmode_oneshot);
            vrchk(vrep, res, true);
            pause(1);
            for i = 1:5,
                if i == 4
                    pause(1);
                end
                res = vrep.simxSetJointTargetPosition(id, h.armJoints(6-i),...
                    startingJoints(6-i),...
                    vrep.simx_opmode_oneshot_wait);
                vrchk(vrep, res, true);
            end
            pause(1);
            fsm = 'find closest box';
            objectLocated = false;
            objectIdentified = false;
        end
        
    elseif strcmp(fsm, 'throw')
        vrep.simxSetIntegerSignal(id, 'km_mode', 0, vrep.simx_opmode_oneshot_wait);
        vrchk(vrep, res, true);
        
        % Setting the arm  to its throwing configuration
        for i = 1:5,
            res = vrep.simxSetJointTargetPosition(id, h.armJoints(i),...
                throwJoints(i),...
                vrep.simx_opmode_oneshot_wait);
            vrchk(vrep, res, true);
        end
        pause(2);
        
        % open the gripper to throw  the object
        vrep.simxSetIntegerSignal(id, 'gripper_open', 1, vrep.simx_opmode_oneshot);
        vrchk(vrep, res, true);
        pause(1);
        
        % Setting the arm to its starting configuration
        for i = 1:5,
            res = vrep.simxSetJointTargetPosition(id, h.armJoints(i),...
                startingJoints(i),...
                vrep.simx_opmode_oneshot_wait);
            vrchk(vrep, res, true);
        end
        pause(1);
        
        % Go back to the table to grab another  object
        goal = table1;
        fsm = 'go to table/basket';
        startGoing = true;
        objectPickedUp = false;
        
    end
    
    % Update wheel velocities
    res = vrep.simxPauseCommunication(id, true); vrchk(vrep, res);
    vrep.simxSetJointTargetVelocity(id, h.wheelJoints(1),...
        -forwBackVel-leftRightVel+rotVel,...
        vrep.simx_opmode_oneshot); vrchk(vrep, res);
    vrep.simxSetJointTargetVelocity(id, h.wheelJoints(2),...
        -forwBackVel+leftRightVel+rotVel,...
        vrep.simx_opmode_oneshot); vrchk(vrep, res);
    vrep.simxSetJointTargetVelocity(id, h.wheelJoints(3),...
        -forwBackVel-leftRightVel-rotVel,...
        vrep.simx_opmode_oneshot); vrchk(vrep, res);
    vrep.simxSetJointTargetVelocity(id, h.wheelJoints(4),...
        -forwBackVel+leftRightVel-rotVel,...
        vrep.simx_opmode_oneshot); vrchk(vrep, res);
    res = vrep.simxPauseCommunication(id, false); vrchk(vrep, res);
    
    % Make sure that we do not go faster that the simulator
    elapsed = toc(sim_timer);
    timeleft = timestep-elapsed;
    if (timeleft > 0),
        pause(min(timeleft, .01));
    end
end
end
