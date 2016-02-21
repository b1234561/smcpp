cimport numpy as np
from cython.operator cimport dereference as deref, preincrement as inc

import random
import sys
import numpy as np
import logging
import collections
import scipy.optimize

T_MAX = C_T_MAX - 0.1

init_eigen();
logger = logging.getLogger(__name__)

abort = False
cdef void logger_cb(const char* name, const char* level, const char* message) with gil:
    global abort
    try:
        lvl = {"INFO": logging.INFO, "DEBUG": logging.DEBUG - 1, "WARNING": logging.WARNING}
        logging.getLogger(name).log(lvl[level.upper()], message)
    except KeyboardInterrupt:
        logging.getLogger(name).critical("Aborting")
        abort = True

init_logger_cb(logger_cb);

# Everything needs to be C-order contiguous to pass in as
# flat arrays
aca = np.ascontiguousarray

cdef vector[double*] make_mats(mats):
    cdef vector[double*] expM
    cdef double[:, :, ::1] mmats = aca(mats)
    cdef int i
    for i in range(mats.shape[0]):
        expM.push_back(&mmats[i, 0, 0])
    return expM

cdef ParameterVector make_params(params):
    cdef vector[vector[double]] ret
    for p in params:
        ret.push_back(p)
    return ret

cdef _make_em_matrix(vector[pMatrixD] mats):
    cdef double[:, ::1] v
    ret = []
    for i in range(mats.size()):
        m = mats[i][0].rows()
        n = mats[i][0].cols()
        ary = aca(np.zeros([m, n]))
        v = ary
        store_matrix[double](mats[i], &v[0, 0])
        ret.append(ary)
    return ret

def validate_observation(ob):
    if np.isfortran(ob):
        raise ValueError("Input arrays must be C-ordered")
    if np.any(np.logical_and(ob[:, 1] == 2, ob[:, 2] == ob[:, 3])):
        raise RuntimeError("Error: data set contains sites where every individual is homozygous recessive. "
                           "Please encode / fold these as non-segregating (homozygous dominant).")

cdef class PyInferenceManager:
    cdef InferenceManager *_im
    cdef int _n, _nder
    cdef int _num_hmms
    cdef object _observations
    cdef public long long seed

    def __cinit__(self, int n, observations, hidden_states, double theta, double rho):
        self.seed = 1
        self._n = n
        cdef int[:, ::1] vob
        cdef vector[int*] obs
        if len(observations) == 0:
            raise RuntimeError("Observations list is empty")
        self._observations = observations
        Ls = []
        ## Validate hidden states
        if any([not np.all(np.sort(hidden_states) == hidden_states),
            hidden_states[0] != 0., hidden_states[-1] > T_MAX]):
            raise RuntimeError("Hidden states must be in ascending order with hs[0]=0 and hs[-1] < %g" % T_MAX)
        for ob in observations:
            validate_observation(ob)
            vob = ob
            obs.push_back(&vob[0, 0])
            Ls.append(ob.shape[0])
        self._num_hmms = len(observations)
        cdef vector[double] hs = hidden_states
        cdef vector[int] _Ls = Ls
        with nogil:
            self._im = new InferenceManager(n, _Ls, obs, hs, theta, rho)

    def __dealloc__(self):
        del self._im

    def get_observations(self):
        return self._observations

    def set_params(self, model, derivatives):
        global abort
        if abort:
            abort = False
            raise KeyboardInterrupt
        logger.debug("Updating params")
        if not np.all(model.x > 0):
            raise ValueError("All parameters must be strictly positive")
        cdef ParameterVector p = make_params(model.x)
        cdef vector[pair[int, int]] _derivatives
        if derivatives:
            # It should be pairs of tuples in this case
            self._nder = len(derivatives)
            _derivatives = derivatives
            with nogil:
                self._im.setParams_ad(p, _derivatives)
        else:
            self._nder = 0
            with nogil:
                self._im.setParams_d(p)
        logger.debug("Updating params finished.")

    def E_step(self, forward_backward_only=False):
        logger.debug("Forward-backward algorithm...")
        cdef bool fbOnly = forward_backward_only
        with nogil:
            self._im.Estep(fbOnly)
        logger.debug("Forward-backward algorithm finished.")

    property span_cutoff:
        def __get__(self):
            return self._im.spanCutoff
        def __set__(self, bint sc):
            self._im.spanCutoff = sc

    property regularizer:
        def __get__(self):
            cdef adouble reg
            cdef double[::1] vjac
            with nogil:
                reg = self._im.getRegularizer()
            if self._nder == 0:
                return toDouble(reg)
            else:
                jac = np.zeros(self._nder)
                vjac = jac
                fill_jacobian(reg, &vjac[0])
                return (toDouble(reg), jac)

    property save_gamma:
        def __get__(self):
            return self._im.saveGamma
        def __set__(self, bint sg):
            self._im.saveGamma = sg

    property hidden_states:
        def __get__(self):
            return self._im.hidden_states
        def __set__(self, hs):
            self._im.hidden_states = hs

    property emission_probs:
        def __get__(self):
            cdef map[block_key, Vector[adouble]] ep = self._im.getEmissionProbs()
            cdef map[block_key, Vector[adouble]].iterator it = ep.begin()
            cdef pair[block_key, Vector[adouble]] p
            ret = {}
            while it != ep.end():
                p = deref(it)
                key = [0] * 3
                for i in range(3):
                    key[i] = p.first[i]
                M = p.second.size()
                v = np.zeros(M)
                if self._nder > 0:
                    dv = np.zeros([M, self._nder])
                for i in range(M):
                    v[i] = p.second(i).value()
                    for j in range(self._nder):
                        dv[i, j] = p.second(i).derivatives()(j)
                ret[tuple(key)] = (v, dv) if self._nder else v
                inc(it)
            return ret


    property gamma_sums:
        def __get__(self):
            ret = []
            cdef vector[pBlockMap] gs = self._im.getGammaSums()
            cdef vector[pBlockMap].iterator it = gs.begin()
            cdef map[block_key, Vector[double]].iterator map_it
            cdef pair[block_key, Vector[double]] p
            cdef double[::1] vary
            cdef int M = len(self.hidden_states) - 1
            while it != gs.end():
                map_it = deref(it).begin()
                pairs = {}
                while map_it != deref(it).end():
                    p = deref(map_it)
                    bk = [0, 0, 0]
                    ary = np.zeros(M)
                    for i in range(3):
                        bk[i] = p.first[i]
                    for i in range(M):
                        ary[i] = p.second(i)
                    pairs[tuple(bk)] = ary
                    inc(map_it)
                inc(it)
                ret.append(pairs)
            return ret

    property gammas:
        def __get__(self):
            return _make_em_matrix(self._im.getGammas())

    property xisums:
        def __get__(self):
            return _make_em_matrix(self._im.getXisums())

    property pi:
        def __get__(self):
            return _store_admatrix_helper(self._im.getPi(), self._nder)

    property transition:
        def __get__(self):
            return _store_admatrix_helper(self._im.getTransition(), self._nder)

    property emission:
        def __get__(self):
            return _store_admatrix_helper(self._im.getEmission(), self._nder)

    def _call_inference_func(self, func):
        cdef vector[double] llret
        if func == "loglik":
            with nogil:
                llret = self._im.loglik()
            return llret
        cdef vector[adouble] ad_rets 
        with nogil:
            ad_rets = self._im.Q()
        cdef int K = ad_rets.size()
        ret = []
        cdef double[::1] vjac
        for i in range(self._num_hmms):
            if (self._nder > 0):
                jac = aca(np.zeros([self._nder]))
                vjac = jac
                fill_jacobian(ad_rets[i], &vjac[0])
                ret.append((toDouble(ad_rets[i]), jac))
            else:
                ret.append(toDouble(ad_rets[i]))
        return ret

    def Q(self):
        return self._call_inference_func("Q")

    def loglik(self):
        return self._call_inference_func("loglik")

def balance_hidden_states(params, int M):
    M -= 1
    cdef ParameterVector p = make_params(params)
    cdef vector[double] v = []
    cdef PiecewiseExponentialRateFunction[double] *eta = new PiecewiseExponentialRateFunction[double](p, v)
    try:
        ret = [0.0]
        t = 0
        for m in range(1, M):
            def f(double t):
                cdef double Rt = eta.R(t)
                return np.exp(-Rt) - 1.0 * (M - m) / M
            res = scipy.optimize.brentq(f, ret[-1], T_MAX)
            ret.append(res)
    finally:
        del eta
    if ret[-1] < T_MAX:
        ret.append(T_MAX)
    return np.array(ret)

def sfs(int n, params, double t1, double t2, double theta, jacobian=False):
    cdef ParameterVector p = make_params(params)
    cdef Matrix[double] sfs
    cdef Matrix[adouble] dsfs
    ret = aca(np.zeros([3, n - 1]))
    cdef double[:, ::1] vret = ret
    if not jacobian:
        sfs = sfs_cython[double](n, p, t1, t2, theta)
        store_matrix(&sfs, &vret[0, 0])
        return ret
    J = len(jacobian)
    jac = aca(np.zeros([3, n - 1, J]))
    cdef double[:, :, ::1] vjac = jac
    dsfs = sfs_cython[adouble](n, p, t1, t2, theta, jacobian)
    return _store_admatrix_helper(dsfs, J)

cdef _store_admatrix_helper(Matrix[adouble] &mat, int nder):
    cdef double[:, ::1] v
    cdef double[:, :, ::1] av
    m = mat.rows()
    n = mat.cols()
    ary = aca(np.zeros([m, n]))
    v = ary
    if (nder == 0):
        store_admatrix(mat, nder, &v[0, 0], NULL)
        return ary
    else:
        jac = aca(np.zeros([m, n, nder]))
        av = jac
        store_admatrix(mat, nder, &v[0, 0], &av[0, 0, 0])
        return ary, jac

def thin_data(data, int thinning, int offset=0):
    '''Implement the thinning procedure needed to break up correlation
    among the full SFS emissions.'''
    # Thinning
    cdef int i = offset
    out = []
    cdef int[:, :] vdata = data
    cdef int k = data.shape[0]
    cdef int span, a, b, nb, a1
    for j in range(k):
        span = vdata[j, 0]
        a = vdata[j, 1]
        b = vdata[j, 2]
        nb = vdata[j, 3]
        a1 = a
        if a1 == 2:
            a1 = 0
        while span > 0:
            if i < thinning and i + span >= thinning:
                if thinning - i > 1:
                    out.append([thinning - i - 1, a1, 0, 0])
                if a == 2 and b == nb:
                    out.append([1, 0, 0, nb])
                else:
                    out.append([1, a, b, nb])
                span -= thinning - i
                i = 0
            else:
                out.append([span, a1, 0, 0])
                i += span
                break
    return np.array(out, dtype=np.int32)
