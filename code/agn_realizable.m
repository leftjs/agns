function [gen, discrim, objective] = agn_realizable( varargin )

    % data and models' paths
    opts.db_path = 'data/eyeglasses/';
    opts.train_filenames = 'data/eyeglasses-training.txt';
    opts.gen_path = 'models/gen.mat';
    opts.discrim_path = 'models/discrim.mat';
    opts.face_net_path = 'models/vgg143-recognition-nn.mat';
    % GAN opts
    opts.init = false;
    opts.sample_latent = @(n,d)(single(2*(rand(n,d)-0.5)));
    opts.latent_dim = 25;
    opts.ngf = 20;
    opts.im_size = [224 224];
    opts.im_crop = [53 25 53+64-1 25+176-1];
    opts.transform = @(im)(single(permute(im, [4 3 1 2]))/127.5 - 1);
    opts.inv_transform = @(im)((permute(im, [3 4 2 1])+1)*127.5);
    opts.inv_transform_dzdx = @(im)(single(permute(im, [4 3 1 2]))*127.5);
    opts.simplenn_preprocess = @(x)(x);
    % progress img name
    opts.prog_img_name = 'progress_agn_realizable.png';
    % attack settings and params
    opts.attack = 'dodge';
    opts.targets = 142;
    opts.face_im_paths = {'data/demo-data1/aligned_vgg_brad_pitt.jpg'};
    opts.mask_path = 'data/eyeglasses_mask_6percent.png';
    opts.face_size = [224 224];
    opts.kappa = 0.8; % coefficient to weigh inconspicuousness
    opts.stop_prob = 0.02; % stopping probability
    opts.stop_checkpt = 100;
    opts.stop_check_interval = 20;
    % "training" options
    opts.n_epochs = 100;
    opts.batch_size = 64;
    opts.k = 1; % train discrim k iteration per 1 gen iteration
    opts.lr_discrim = 2e-5; % learning rate for discriminator
    opts.lr_gen = 2e-5; % learning rate for generator
    opts.weight_decay = 5e-5; % weight decay
    opts.b1 = 0.5; % \beta1 from ADAM
    opts.b2 = 0.999; % \beta2 from ADAM
    opts.eps = 1e-8; % \eps from ADAM
    opts.t_discrim = 0; % # updates for discriminator
    opts.t_gen = 0; % # updates for generator
    opts.weights_init = @(sz)(single(0.02*randn(sz)));
    opts.bias_init = @(sz)(single(0.02*zeros(sz)));
    opts.one_label_smooth = 0.9; % one sided label smoothing
    opts.platform = 'cpu';
    % transforming eyeglasses to the input image
    opts.eyeglass_tforms = [];
    opts = vl_argparse(opts, varargin);

    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % load gen and discrim and init
    % their weights
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    gen = load_eyeglass_generator(opts.gen_path, '', opts.ngf);
    discrim = load_eyeglass_discriminator(opts.discrim_path, '' );
    face_net = load_face_net(opts.face_net_path);
    if opts.init
        gen = init_net(gen, opts.weights_init, opts.bias_init);
        discrim = init_net(discrim, opts.weights_init, opts.bias_init);
    end
    if strcmp(opts.platform, 'gpu')
        discrim = vl_simplenn_move(discrim, 'gpu');
        gen = vl_simplenn_move(gen, 'gpu');
        face_net = vl_simplenn_move(face_net, 'gpu');
        opts.simplenn_preprocess = @(x)(gpuArray(x));
        opts.inv_transform = @(im)((permute(gather(im), [3 4 2 1])+1)*127.5);
        opts = vl_argparse(opts, varargin);
    end
    
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % load images
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    imdb = get_imdb(opts.train_filenames, opts.db_path, opts.im_size, opts.im_crop, opts.transform);
    [face_ims, masks] = get_face_ims(opts);
    
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % "train" generator to create attacks
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    objective = struct('gen_face', [], 'gen_inc', [], 'discrim', []);
    epoch = 1; done = false;
    while epoch<=opts.n_epochs && ~done
        i = 1; j = 1;
        imdb.images = imdb.images(randperm(size(imdb.images,1)), :, :, :);
        objs_d = []; objs_g_face = []; objs_g_inc = [];
        while i<=size(imdb.images,1)
            last_idx = min( size(imdb.images,1), i+(opts.batch_size)/2-1 );
            ims = imdb.images(i:last_idx, :, :, :);
            z = opts.sample_latent(size(ims,1), opts.latent_dim);
            if mod(j,opts.k+1)~=0 && opts.kappa>0
                % train discriminator
                opts.t_discrim = opts.t_discrim + 1;
                [discrim, obj] = discrim_update(opts, discrim, gen, ims, z);
                objs_d = [objs_d obj];
            else
                % train generator
                opts.t_gen = opts.t_gen + 1;
                [gen, obj_inc, obj_face] = gen_update(opts, discrim, gen, ims, z,...
                                                                face_net, face_ims, masks);
                fprintf('obj_face = %0.4e\n',obj_face);
                objs_g_inc = [objs_g_inc obj_inc];
                objs_g_face = [objs_g_face obj_face];
            end
            % target stopping probability reached
            if (j==opts.stop_checkpt || (j>opts.stop_checkpt && mod(j,opts.stop_check_interval)==0)) ...
                    && objective_met(opts, face_net, face_ims, masks, gen)
                objective.n_epochs = epoch;
                objective.iters = j;
                done = true;
                break;
            end
            i = last_idx + 1;
            j = j + 1;
        end
        % plot progress
        objective.discrim = [objective.discrim mean(objs_d)];
        objective.gen_face = [objective.gen_face mean(objs_g_face)];
        objective.gen_inc = [objective.gen_inc mean(objs_g_inc)];
        z = opts.sample_latent(opts.batch_size, opts.latent_dim);
        res = vl_simplenn(gen, z);
        show_progress(objective, res(end).x, opts);
        fprintf('Done with epoch %d\n', epoch);
        prog_im = getframe(gcf);
        imwrite(prog_im.cdata, ['results/' opts.prog_img_name]);
        epoch = epoch + 1;
    end
    
    % move back to cpu if necessary
    if strcmp(opts.platform, 'gpu')
        discrim = vl_simplenn_move(discrim, 'cpu');
        gen = vl_simplenn_move(gen, 'cpu');
    end
    
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Auxiliary functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% check whether to stop the
% optimization
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function done = objective_met(opts, face_net, face_ims, masks, gen)
    z_ = opts.sample_latent(opts.batch_size/2, opts.latent_dim);
    res_gen = vl_simplenn(gen, opts.simplenn_preprocess(z_));
    gen_out = res_gen(end).x;
    n = size(face_ims,4);
    for i_g = 1:opts.batch_size/2
        % classify faces with eyeglasses
        probs = zeros(n,1);
        for i_f = 1:opts.batch_size/2:n
            n_iter = min([opts.batch_size/2 n-i_f+1]);
            tmp = opts.transform(zeros(opts.im_size(1), opts.im_size(2), 3, n_iter));
            g = repmat(gen_out(i_g,:,:,:), [n_iter 1 1 1]);
            tmp(:,:,opts.im_crop(1):opts.im_crop(3), opts.im_crop(2):opts.im_crop(4)) = gather(g);
            g = resize(opts.inv_transform(tmp), opts.face_size);
            masks_iter = masks(:,:,:,1:n_iter);
            for i_g2 = 1:n_iter
                [im, mask] = transform_eyeglasses(g(:,:,:,i_g2), masks_iter(:,:,:,i_g2), opts.eyeglass_tforms(i_f+i_g2-1));
                g(:,:,:,i_g2) = im;
                masks_iter(:,:,:,i_g2) = mask;
            end
            face_ims_iter = face_ims(:,:,:,i_f:i_f+n_iter-1);
            face_ims_iter(masks_iter) = g(masks_iter);
            if strcmp(opts.platform, 'gpu')
                face_ims_iter = gpuArray(face_ims_iter);
            end
            % classify the faces
            res_faces = vl_simplenn(face_net, face_ims_iter);
            % check if the mean of the target's probability is in the
            % the desired range (for the current sample)
            targets = opts.targets(i_f:i_f+n_iter-1);
            for i_t = 1:n_iter
                probs(i_f+i_t-1) = gather(res_faces(end).x(:,:,targets(i_t),i_t));
            end
        end
        if ( (mean(probs)<=opts.stop_prob && strcmp(opts.attack, 'dodge')) || ...
             (mean(probs)>=opts.stop_prob && ~strcmp(opts.attack, 'dodge')) )
            done = true;
            return;
        end
    end
    done = false;
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% discrim update
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function [discrim, obj] = discrim_update(opts, discrim, gen, ims, z)
    res_gen = vl_simplenn(gen, opts.simplenn_preprocess(z));
    gen_out = res_gen(end).x;
    batch = cat(1, ims, gen_out);
    l = struct('type', 'bce', 'p', []); % bce layer for training
    p = [opts.one_label_smooth*single(ones(size(ims,1),1)); single(zeros(size(ims,1),1))];
    l.p = p;
    discrim.layers{end+1} = l;
    [discrim, obj] = update_model(opts, discrim, batch, opts.lr_discrim, opts.t_discrim);
    discrim.layers = discrim.layers(1:end-1);
end
    
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% gen update
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function [gen, obj_d, obj_f] = gen_update(opts, discrim, gen, ims, z, face_net, face_ims, masks)
    res_gen = vl_simplenn(gen, opts.simplenn_preprocess(z));
    gen_out = res_gen(end).x;
    batch = cat(1, ims, gen_out);
    % derivative from discriminator
    l = struct('type', 'bce', 'p', []); % bce layer for training
    p = opts.one_label_smooth*single(ones(size(batch,1),1));
    l.p = p;
    discrim.layers{end+1} = l;
    res_discrim = vl_simplenn(discrim, opts.simplenn_preprocess(batch), 1, [], ...
                      'backPropDepth', +inf);
    dgdz_d = res_discrim(1).dzdx;
    dgdz_d = dgdz_d(size(ims,1)+1:end,:,:,:);
    % derivative from face recognition
    n = size(z,1);
    [face_ims, targets, eyeglass_tforms] = sample_ims(face_ims, n, opts);
    face_net = switch_to_our_objective_layer(face_net, targets); % switch last layer to softmax loss
    masks = masks(:,:,:,1:n);
    face_ims = faces_wearing_gen(opts, face_ims, gen_out, masks, eyeglass_tforms);
    res_faces = vl_simplenn(face_net, face_ims, 1, [], ...
                    'backPropDepth', +inf);
	dgdz_f = res_faces(1).dzdx;
    dgdz_f = gen_facenet_gradients(opts, dgdz_f, masks, eyeglass_tforms);
    if strcmp(opts.attack, 'dodge')
        dgdz_f = -dgdz_f;
    end
    % compute the objectives
    obj_d = mean(gather(res_discrim(end).x));
	obj_f = 0;
    probs = gather(res_faces(end-1).x);
    for t_i = 1:numel(targets)
        obj_f = obj_f + probs(1,1,targets(t_i),t_i);
    end
    obj_f = obj_f/numel(targets);
    % update generator's weights
    dgdz = join_gradients(dgdz_d, dgdz_f, opts.kappa);
    [gen, ~] = update_model(opts, gen, batch, opts.lr_gen, opts.t_gen, res_gen, dgdz);
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Join faces with generated accessories
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function face_ims = faces_wearing_gen(opts, face_ims, gen_out, masks, eyeglass_tforms)
    % Resize gen_out
    n = size(gen_out,1);
    if strcmp(opts.platform, 'cpu')
        % on cpu
        tmp = opts.transform(zeros(opts.im_size(1), opts.im_size(2), 3, n));
        tmp(:,:,opts.im_crop(1):opts.im_crop(3), opts.im_crop(2):opts.im_crop(4)) = gen_out;
        gen_out = resize(opts.inv_transform(tmp), opts.face_size);
    else
        % on gpu (can only resize by scale)
        tmp = opts.transform(zeros(opts.im_size(1), opts.im_size(2), 3, n));
        tmp(:,:,opts.im_crop(1):opts.im_crop(3), opts.im_crop(2):opts.im_crop(4)) = gather(gen_out);
        gen_out = gpuArray(tmp);
        gen_out = resize(opts.inv_transform(gen_out), opts.face_size(1)/opts.im_size(1));
    end
    % Transform generated (eyeglass) images, and add them to faces
    for i_im = 1:size(face_ims,4)
        g = gen_out(:,:,:,i_im);
        mask = masks(:,:,:,i_im);
        [g, mask] = transform_eyeglasses(g, mask, eyeglass_tforms(i_im));
        f = face_ims(:,:,:,i_im);
        f(mask) = g(mask);
        face_ims(:,:,:,i_im) = f;
    end
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Reverse eyeglass transformations to get
% generator's gradients from the face-
% recognition DNN
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function dgdz_f = gen_facenet_gradients(opts, dgdz_f, masks, eyeglass_tforms)
    % reverse random movement
    tmp = zeros(size(dgdz_f(:,:,:,1)));
    for d_i = 1:size(dgdz_f,4)
        inv_tform = invert(eyeglass_tforms(d_i));
        tformed_grad = transform_eyeglasses(gather(dgdz_f(:,:,:,d_i)), tmp, inv_tform);
        if isa(dgdz_f, 'gpuArray')
            tformed_grad = gpuArray(tformed_grad);
        end
        dgdz_f(:,:,:,d_i) = tformed_grad;
    end
    % resize, and zero out entries not on masks
    dgdz_f(~masks) = 0;
    if strcmp(opts.platform, 'cpu')
        % resize on cpu
        dgdz_f = opts.inv_transform_dzdx(resize(dgdz_f, opts.im_size));
    else
        % resize on gpu (can only resize by scale)
        dgdz_f = opts.inv_transform_dzdx(resize(dgdz_f, opts.im_size(1)/opts.face_size(1)));
    end
    dgdz_f = dgdz_f(:, :, opts.im_crop(1):opts.im_crop(3), opts.im_crop(2):opts.im_crop(4));
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Join the gradients (from the
% discriminator and the generator)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function d = join_gradients(dgdz_d, dgdz_f, kappa)
    % check kappa's range
    if kappa<0 || kappa>1
        error('kappa has to be in the [0,1] range!');
    end
    % join gradients
    d = dgdz_d;
    for d_i = 1:size(dgdz_d,1)
        d1 = dgdz_d(d_i,:,:,:);
        d2 = dgdz_f(d_i,:,:,:);
        if norm(d1(:))>norm(d2(:))
            d1 = d1*norm(d2(:))/norm(d1(:));
        else
            d2 = d2*norm(d1(:))/norm(d2(:));
        end
        d(d_i,:,:,:) = kappa*d1 + (1-kappa)*d2;
    end
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Update neural network
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function [net, obj] = update_model(opts, net, batch, lr, iter, res_simplenn, dzdy)
    if nargin<6
        res_simplenn = vl_simplenn(net, opts.simplenn_preprocess(batch), 1, [], ...
                          'backPropDepth', +inf);
    else
        res_simplenn = vl_simplenn(net, opts.simplenn_preprocess(batch), dzdy, res_simplenn, ...
                          'backPropDepth', +inf);
    end
    net = adam_update(opts, net, res_simplenn, lr, iter);
    obj = mean(gather(res_simplenn(end).x));
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% accumulate gradients--adapted from
% Vedaldi's example
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function net = adam_update(opts, net, res, lr, t)
    % parameters
    b1 = opts.b1; b2 = opts.b2;
    eps = opts.eps; decay = opts.weight_decay;
    batch_size = opts.batch_size;
    % update weights
    for l_i=1:numel(net.layers)
      for d_i=1:numel(res(l_i).dzdw)

        if isfield(net.layers{l_i}, 'weights') && ~isempty(net.layers{l_i}.weights{d_i})
            % weight decay
            res(l_i).dzdw{d_i} = res(l_i).dzdw{d_i} + decay * net.layers{l_i}.weights{d_i};
            % compute update
            if isfield(net.layers{l_i}, 'm') && d_i<=numel(net.layers{l_i}.m)
                net.layers{l_i}.m{d_i} = ...
                    b1 * net.layers{l_i}.m{d_i} ...
                    + (1-b1) * (1/batch_size) * res(l_i).dzdw{d_i};
                net.layers{l_i}.v_{d_i} = ...
                    b2 * net.layers{l_i}.v_{d_i} ...
                    + (1-b2) * ( (1/batch_size) * res(l_i).dzdw{d_i}).^2;
            else
                net.layers{l_i}.m{d_i} = ...
                    (1-b1) * (1/batch_size) * res(l_i).dzdw{d_i} ;
                net.layers{l_i}.v_{d_i} = ...
                    (1-b2) * ((1/batch_size) * res(l_i).dzdw{d_i}).^2 ;
            end
            m_hat =  net.layers{l_i}.m{d_i} / (1-b1^t);
            v_hat =  net.layers{l_i}.v_{d_i} / (1-b2^t);
            update = - lr * (m_hat./(sqrt(v_hat)+eps));
            update( isnan(update) ) = 0;
            % update
            net.layers{l_i}.weights{d_i} = net.layers{l_i}.weights{d_i} + update;
        end
      end
    end
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% switch last layer to softmax loss
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function net = switch_to_our_objective_layer(net, targets)
    l = struct('type', 'our_loss', 'class', targets(:));
    net.layers{end+1} = l;
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% show progress
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function show_progress(objective, gen_out_samples, opts)
    % display gen_out_sample
    subplot(1,2,1);
    imshow( vl_imarray(uint8(opts.inv_transform(gen_out_samples))) );
    % graph showing progress of objectives
    subplot(1,2,2); hold off;
    plot(1:numel(objective.discrim), objective.discrim, 'LineWidth', 2);
    hold on;
    plot(1:numel(objective.gen_inc), objective.gen_inc, 'LineWidth', 2);
    plot(1:numel(objective.gen_face), objective.gen_face, 'LineWidth', 2);
    legend({'discrim', 'gen', 'face-rec'});
    xlabel('epoch'); ylabel('obj');
    set(gca, 'FontSize', 16);
    grid on;
    set(gcf, 'Position', [0 0 1200 800]);
    drawnow;
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% init weights
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function net = init_net(net, weights_init, bias_init)
    for l_i = 1:numel(net.layers)
        if isfield(net.layers{l_i}, 'weights')
            net.layers{l_i}.weights{1} = weights_init(size(net.layers{l_i}.weights{1}));
            if strcmp(net.layers{l_i}.type, 'bnorm_custom') || strcmp(net.layers{l_i}.type, 'bnorm')
                net.layers{l_i}.weights{1} = net.layers{l_i}.weights{1} + 1;
            end
            if numel(net.layers{l_i}.weights)>1
                net.layers{l_i}.weights{2} = bias_init(size(net.layers{l_i}.weights{2}));
            end
        end
    end
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% load vgg face-rec dnn
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function  net = load_face_net(face_net_path)
    data = load(face_net_path);
    net = data.net;
    [net, ~] = change_dropout_rates(net, 0);
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% load face to be used for fooling
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function [face_ims, masks] = get_face_ims(opts)
    face_ims = single(zeros(opts.face_size(1), opts.face_size(2), 3, numel(opts.face_im_paths)));
    for i_im = 1:numel(opts.face_im_paths)
        im = imread( opts.face_im_paths{i_im} );
        im = imresize(im, opts.face_size);
        face_ims(:,:,:,i_im) = single(im);
    end
    mask = imread(opts.mask_path);
    masks = repmat(mask>50, [1 1 1 opts.batch_size/2]);
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% sample n (face) images, and move
% them to gpu if necessary
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function [ims, targets, eyeglass_tforms] = sample_ims(ims, n, opts)
    idxs = randi(size(ims,4), [1 n]);
    ims = ims(:,:,:,idxs);
    targets = opts.targets(idxs);
    eyeglass_tforms = opts.eyeglass_tforms(idxs);
    if strcmp(opts.platform, 'gpu')
        ims = gpuArray(ims);
    end
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% resize images
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function ims_out = resize(ims, sz)
    if numel(sz)==2
        ims_out = zeros(sz(1), sz(2), size(ims,3), size(ims,4));
    elseif numel(sz)==1
        ims_out = zeros(sz*size(ims,1), sz*size(ims,2), size(ims,3), size(ims,4));
    else
        error('sz can have one or two elements only.');
    end
    if isa(ims, 'gpuArray')
        ims_out = gpuArray(ims_out);
    end
    for im_i = 1:size(ims,4)
        ims_out(:,:,:,im_i) = imresize(ims(:,:,:,im_i), sz);
    end
end

end
