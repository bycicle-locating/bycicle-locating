#include "app_types.h"

bkl_e7_t bkl_e7_from_deg(double deg)
{
    /* 先判断范围，避免 double 超界时转整数是未定义行为 */
    if (deg > 180.0 || deg < -180.0) {
        return 0;
    }
    double scaled = deg * 10000000.0;
    if (scaled >= 0.0) {
        return (bkl_e7_t)(scaled + 0.5);
    }
    return (bkl_e7_t)(scaled - 0.5);
}

double bkl_e7_to_deg(bkl_e7_t v)
{
    return (double)v / 10000000.0;
}

bool bkl_point_is_valid(const bkl_point_t *p)
{
    if (p == NULL) {
        return false;
    }
    if (p->seq == 0) {
        return false;
    }
    /* 纬度 ±90，经度 ±180，单位 1e-7 度 */
    if (p->lat < -900000000 || p->lat > 900000000) {
        return false;
    }
    if (p->lon < -1800000000LL || p->lon > 1800000000LL) {
        return false;
    }
    if (p->fix != BKL_FIX_NONE && p->fix != BKL_FIX_2D && p->fix != BKL_FIX_3D) {
        return false;
    }
    return true;
}
