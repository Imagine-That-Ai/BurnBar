import Foundation
import CoreGraphics

// remediation(core-swarm-decomp): relocated verbatim from SwarmCanvasView.swift to
// shrink that 3,926-line god-file. Behavior-preserving move only; SwiftPM directory
// auto-discovery picks this sibling up automatically.

enum SwarmProviderLogoDotMap {
    struct Point: Equatable {
        let point: CGPoint
        let role: String
        let progress: Double
    }

    static func hermesAgent() -> [Point] {
        decodePackedPoints(hermesAgentPacked, outerRadius: 0.74)
    }

    static func factory() -> [Point] {
        decodePackedPoints(factoryPacked, outerRadius: 0.80)
    }

    private static func decodePackedPoints(_ packed: String, outerRadius: Double) -> [Point] {
        guard let data = Data(base64Encoded: packed, options: .ignoreUnknownCharacters) else { return [] }
        let bytes = [UInt8](data)
        let count = bytes.count / 4
        guard count > 0 else { return [] }

        var points: [Point] = []
        points.reserveCapacity(count)
        for index in 0..<count {
            let offset = index * 4
            let xRaw = Int16(bitPattern: (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1]))
            let yRaw = Int16(bitPattern: (UInt16(bytes[offset + 2]) << 8) | UInt16(bytes[offset + 3]))
            let x = Double(xRaw) / 10_000.0
            let y = Double(yRaw) / 10_000.0
            let radius = hypot(x, y)
            let role: String
            if index.isMultiple(of: 11) {
                role = "logo-flame-spark"
            } else if radius >= outerRadius {
                role = "logo-flame-outer"
            } else {
                role = "logo-flame-inner"
            }
            points.append(Point(
                point: CGPoint(x: x, y: y),
                role: role,
                progress: Double(index) / Double(max(count - 1, 1))
            ))
        }
        return points
    }

    // Generated from /Users/albertonunez/Downloads/hermesagent.svg at 1024px,
    // preserving the SVG filled silhouette while keeping a stable particle count.
    private static let hermesAgentPacked = [
        "+bXZqvso2ar8m9mq/g7Zqv+B2aoA9NmqAmfZqgPa2aoFTdmq8+jbHf4O2x3/gdsdAPTbHQJn2x0D2tsdBU3bHQbB2x0INNsd",
        "CafbHfEC3JDyddyQ8+jckPVb3JD2ztyQ+ELckAD03JACZ9yQA9rckAVN3JAGwdyQCDTckAmn3JALGtyQDI3ckO4c3gPvj94D",
        "8QLeA/J13gPz6N4D9VveA/bO3gP4Qt4D+bXeA/so3gMCZ94DA9reAwVN3gMGwd4DCDTeAwmn3gMLGt4DDI3eAw4A3gPrNt92",
        "7Knfdu4c33bvj9928QLfdvJ133bz6N929VvfdvbO33b4Qt92+bXfdvso33b8m992A9rfdgVN33YGwd92CDTfdgmn33YLGt92",
        "DI3fdg4A33YPc9926FDg6enD4OnrNuDp7Kng6e4c4Onvj+Dp8QLg6fJ14Onz6ODp9Vvg6fbO4On4QuDp+bXg6fso4On8m+Dp",
        "/g7g6f+B4OkFTeDpBsHg6Qg04OkJp+DpCxrg6QyN4OkOAODpD3Pg6RDm4Onm3OJc6FDiXOnD4lzrNuJc7KniXO4c4lzvj+Jc",
        "8QLiXPJ14lzz6OJc9VviXPbO4lz4QuJc+bXiXPso4lz8m+Jc/g7iXP+B4lwGweJcCDTiXAmn4lwLGuJcDI3iXA4A4lwPc+Jc",
        "EObiXBJZ4lzlaePP5tzjz+hQ48/pw+PP6zbjz+yp48/uHOPP74/jz/EC48/ydePP8+jjz/Vb48/2zuPP+ELjz/m148/7KOPP",
        "/Jvjz/4O488A9OPPCDTjzwmn488LGuPPDI3jzw4A488Pc+PPEObjzxJZ48/j9uVC5WnlQubc5ULoUOVC6cPlQus25ULsqeVC",
        "7hzlQu+P5ULxAuVC8nXlQvPo5UL1W+VC9s7lQvhC5UL5teVC+yjlQgJn5UIINOVCCaflQgsa5UIMjeVCDgDlQg9z5UIQ5uVC",
        "FT/lQuKD5rXlaea15tzmtehQ5rXpw+a16zbmteyp5rXuHOa174/mtfEC5rXydea18+jmtfVb5rX2zua1+ELmtfso5rUA9Oa1",
        "AmfmtQmn5rULGua1DI3mtQ4A5rUPc+a1E8zmtRU/5rXj9ugo5WnoKObc6CjoUOgo6cPoKOs26Cjsqego7hzoKPVb6Cj2zugo",
        "/JvoKP4O6Cj/gegoAPToKAPa6CgJp+goDgDoKBU/6CgWs+go4oPpnOVp6Zzm3Omc6FDpnPyb6Zz+Dumc/4HpnAD06ZwCZ+mc",
        "A9rpnAmn6ZwLGumcDI3pnA4A6ZwPc+mcEObpnBJZ6ZwTzOmcFT/pnBaz6Zzj9usP6FDrD+nD6w/sqesP7hzrD++P6w/xAusP",
        "8nXrD/Po6w/1W+sP9s7rD/hC6w/5tesP+yjrD/yb6w/+DusP/4HrDwD06w8CZ+sPA9rrDwsa6w8MjesPDgDrDw9z6w8Q5usP",
        "ElnrDxPM6w8VP+sPFrPrD9+d7ILhEOyC4oPsguP27ILlaeyC5tzsguhQ7ILpw+yC6zbsguyp7ILuHOyC74/sgvEC7ILydeyC",
        "8+jsgvVb7IL2zuyC+ELsgvm17IL7KOyC/Jvsgv4O7IL/geyCAPTsggJn7IID2uyCBU3sggsa7IIMjeyCDgDsgg9z7IIQ5uyC",
        "ElnsghPM7IIVP+yCFrPsghgm7ILfne314RDt9eKD7fXj9u315Wnt9ebc7fXoUO316cPt9es27fXsqe317hzt9e+P7fXxAu31",
        "8nXt9fPo7fX1W+319s7t9fhC7fX5te31+yjt9fyb7fX+Du31/4Ht9QD07fUCZ+31A9rt9QVN7fUGwe31CDTt9Qmn7fULGu31",
        "DI3t9Q4A7fUPc+31EObt9RJZ7fUTzO31FT/t9Raz7fUYJu31353vaOEQ72jig+9o4/bvaOVp72jm3O9o6FDvaOnD72jrNu9o",
        "7KnvaO4c72jvj+9o8QLvaPJ172jz6O9o9VvvaPbO72j4Qu9o+bXvaPso72j8m+9o/g7vaP+B72gA9O9oAmfvaAPa72gFTe9o",
        "CDTvaAmn72gLGu9oDI3vaA4A72gPc+9oEObvaBJZ72gTzO9oFT/vaBaz72gYJu9o3irw29+d8NvhEPDb4oPw2+P28NvlafDb",
        "5tzw2+hQ8Nvpw/Db6zbw2+yp8NvuHPDb74/w2/EC8NvydfDb8+jw2/Vb8Nv2zvDb+ELw2/m18Nv7KPDb/Jvw2/4O8Nv/gfDb",
        "APTw2wJn8NsD2vDbBU3w2wg08NsJp/DbDI3w2w4A8NsPc/DbEObw2xJZ8NsTzPDbFT/w2xaz8NsYJvDbGZnw294q8k7fnfJO",
        "4RDyTuKD8k7j9vJO5WnyTubc8k7oUPJO6cPyTus28k7sqfJO7hzyTu+P8k7xAvJO8+jyTvVb8k72zvJO+ELyTvm18k77KPJO",
        "/JvyTv4O8k7/gfJOAPTyTgJn8k4D2vJOBU3yTgbB8k4INPJOCafyTgsa8k4MjfJODgDyTg9z8k4Q5vJOElnyThPM8k4VP/JO",
        "FrPyThgm8k4ZmfJO3irzwd+d88HhEPPB4oPzweP288HlafPB5tzzwehQ88Hpw/PB6zbzweyp88HuHPPB74/zwfEC88HydfPB",
        "8+jzwfVb88H2zvPB+ELzwfm188H7KPPB/Jvzwf4O88H/gfPBAPTzwQJn88ED2vPBBU3zwQbB88EINPPBCafzwQsa88EMjfPB",
        "DgDzwQ9z88EQ5vPBElnzwRPM88EVP/PBFrPzwRgm88EZmfPB3ir1NN+d9TThEPU04oP1NOP29TTlafU05tz1NOhQ9TTpw/U0",
        "6zb1NOyp9TTuHPU074/1NPEC9TTydfU09Vv1NPbO9TT4QvU0+bX1NPso9TT8m/U0/g71NP+B9TQA9PU0Amf1NAPa9TQFTfU0",
        "BsH1NAg09TQJp/U0Cxr1NAyN9TQOAPU0D3P1NBDm9TQSWfU0E8z1NBU/9TQWs/U0GCb1NBmZ9TTeKvan3532p+EQ9qfig/an",
        "4/b2p+Vp9qfm3Pan6FD2p+nD9qfrNvan7Kn2p+4c9qfvj/an8QL2p/J19qf2zvan+EL2p/m19qf7KPan/Jv2p/4O9qf/gfan",
        "APT2pwJn9qcD2vanBU32pwbB9qcINPanCaf2pwsa9qcMjfanDgD2pw9z9qcQ5vanEln2pxPM9qcVP/anFrP2pxgm9qcZmfan",
        "Gwz2p9+d+BvhEPgb4oP4G+P2+Bvlafgb5tz4G+hQ+Bvvj/gb8nX4G/Po+Bv1W/gbAPT4GwJn+BsD2vgbBU34GwbB+BsINPgb",
        "Caf4Gwsa+BsMjfgbDgD4Gw9z+BsQ5vgbE8z4GxU/+BsWs/gbGCb4GxmZ+BsbDPgb3535juEQ+Y7ig/mO4/b5juVp+Y7pw/mO",
        "8nX5jvPo+Y71W/mO9s75jvhC+Y4A9PmOAmf5jgPa+Y4FTfmOBsH5jgg0+Y4Jp/mOCxr5jgyN+Y4OAPmOD3P5jhDm+Y4SWfmO",
        "E8z5jhU/+Y4Ws/mOGCb5jhmZ+Y4bDPmO4RD7AeKD+wHj9vsB5Wn7Aebc+wHoUPsB6cP7AfPo+wH1W/sB9s77AfhC+wH5tfsB",
        "APT7AQJn+wED2vsBBU37AQbB+wEJp/sBCxr7AQ4A+wEPc/sBEOb7ARJZ+wETzPsBFT/7ARaz+wEYJvsBGZn7ARsM+wHig/x0",
        "4/b8dOVp/HTm3Px06cP8dOs2/HTz6Px09Vv8dPhC/HQA9Px0Amf8dAPa/HQFTfx0BsH8dAg0/HQJp/x0Cxr8dAyN/HQOAPx0",
        "D3P8dBDm/HQSWfx0FT/8dBaz/HQYJvx0GZn8dBsM/HTm3P3n6cP95/Po/ef1W/3nAPT95wJn/ecD2v3nBU395wbB/ecINP3n",
        "Caf95wsa/ecMjf3nDgD95w9z/ecQ5v3nEln95xPM/ecVP/3nFrP95xgm/ecZmf3nGwz95xx//efm3P9a6FD/WunD/1r/gf9a",
        "APT/WgJn/1oD2v9aBU3/WgbB/1oINP9aCaf/Wgsa/1oMjf9aDgD/Wg9z/1oQ5v9aEln/WhPM/1oVP/9aFrP/Whgm/1oZmf9a",
        "Gwz/Whx//1rm3ADN6FAAzf+BAM0A9ADNAmcAzQPaAM0FTQDNBsEAzQg0AM0JpwDNCxoAzQyNAM0OAADND3MAzRDmAM0SWQDN",
        "E8wAzRU/AM0WswDNGCYAzRmZAM0bDADNHH8AzebcAkDoUAJA/4ECQAD0AkACZwJAA9oCQAVNAkAGwQJACDQCQAmnAkALGgJA",
        "DI0CQA4AAkAPcwJAEOYCQBJZAkATzAJAFT8CQBazAkAYJgJAGZkCQBsMAkAcfwJA5twDs/+BA7MA9AOzAmcDswPaA7MFTQOz",
        "BsEDswg0A7MJpwOzCxoDswyNA7MOAAOzD3MDsxDmA7MSWQOzE8wDsxU/A7MWswOzGCYDsxmZA7MbDAOzHH8Dsx3yA7PlaQUm",
        "5twFJv+BBSYA9AUmAmcFJgPaBSYFTQUmBsEFJgg0BSYJpwUmCxoFJgyNBSYOAAUmD3MFJhDmBSYSWQUmE8wFJhU/BSYWswUm",
        "GCYFJhmZBSYbDAUmHH8FJh3yBSblaQaZ5twGmenDBpn/gQaZAPQGmQJnBpkD2gaZBU0GmQbBBpkINAaZCacGmQsaBpkMjQaZ",
        "DgAGmQ9zBpkQ5gaZElkGmRPMBpkVPwaZFrMGmRgmBpkZmQaZGwwGmRx/Bpkd8gaZ5WkIDebcCA3rNggN7KkIDf4OCA3/gQgN",
        "APQIDQJnCA0D2ggNBU0IDQbBCA0INAgNCacIDQsaCA0MjQgNDgAIDQ9zCA0Q5ggNElkIDRPMCA0VPwgNFrMIDRgmCA0ZmQgN",
        "GwwIDRx/CA0d8ggN5WkJgObcCYDoUAmA6zYJgO+PCYD+DgmA/4EJgAD0CYACZwmAA9oJgAbBCYAINAmACacJgAsaCYAMjQmA",
        "DgAJgA9zCYAQ5gmAElkJgBPMCYAVPwmAFrMJgBgmCYAZmQmAGwwJgBx/CYAd8gmAH2UJgOVpCvPm3Arz6FAK8+s2CvPsqQrz",
        "/g4K8/+BCvMA9ArzAmcK8wPaCvMGwQrzCDQK8wmnCvMLGgrzDI0K8w4ACvMPcwrzEOYK8xJZCvMTzArzFT8K8xazCvMYJgrz",
        "GZkK8xsMCvMcfwrzHfIK8x9lCvPlaQxm5twMZuhQDGbpwwxm/g4MZv+BDGYA9AxmAmcMZgPaDGYGwQxmCDQMZgmnDGYLGgxm",
        "DI0MZg4ADGYPcwxmEOYMZhJZDGYTzAxmFT8MZhazDGYYJgxmGZkMZhsMDGYd8gxmH2UMZuVpDdnm3A3Z6FAN2enDDdn+Dg3Z",
        "/4EN2QD0DdkCZw3ZBsEN2Qg0DdkJpw3ZCxoN2QyNDdkOAA3ZD3MN2RDmDdkSWQ3ZE8wN2RU/DdkWsw3ZGCYN2RmZDdkbDA3Z",
        "HfIN2R9lDdnctw9M5WkPTObcD0zoUA9M6cMPTOs2D0z+Dg9M/4EPTAD0D0wCZw9MBU0PTAbBD0wINA9MCacPTAsaD0wMjQ9M",
        "DgAPTA9zD0wQ5g9MElkPTBPMD0wVPw9MFrMPTBgmD0wZmQ9MGwwPTB3yD0wfZQ9MINgPTNy3EL/j9hC/5WkQv+bcEL/oUBC/",
        "6cMQv+s2EL/+DhC//4EQvwD0EL8CZxC/A9oQvwVNEL8GwRC/CDQQvwmnEL8LGhC/DI0Qvw4AEL8PcxC/EOYQvxJZEL8TzBC/",
        "FT8QvxazEL8YJhC/GZkQvxsMEL8d8hC/H2UQvyDYEL/bRBIy3LcSMuP2EjLlaRIy5twSMuhQEjLpwxIy6zYSMuypEjLuHBIy",
        "748SMvECEjLydRIy8+gSMvVbEjL2zhIy/g4SMv+BEjIA9BIyAmcSMgPaEjIGwRIyCDQSMgmnEjILGhIyDI0SMg4AEjIPcxIy",
        "EOYSMhJZEjITzBIyFT8SMhazEjIYJhIyGZkSMhsMEjId8hIyH2USMiDYEjIjvhIy20QTpdy3E6Xj9hOl5WkTpebcE6XoUBOl",
        "6cMTpes2E6XsqROl7hwTpe+PE6XxAhOl8nUTpfPoE6X1WxOl9s4TpfhCE6X+DhOl/4ETpQD0E6UCZxOlBsETpQg0E6UJpxOl",
        "CxoTpQyNE6UOABOlD3MTpRDmE6USWROlE8wTpRU/E6UWsxOlGCYTpRmZE6UbDBOlHfITpR9lE6Ug2BOlI74Tpdy3FRjeKhUY",
        "350VGOEQFRjigxUY4/YVGOVpFRjm3BUY6FAVGOnDFRjrNhUY7KkVGO4cFRjvjxUY8QIVGPJ1FRjz6BUY9VsVGPbOFRj4QhUY",
        "+bUVGP4OFRj/gRUYAPQVGAJnFRgGwRUYCDQVGAmnFRgLGhUYDI0VGA4AFRgPcxUYEOYVGBJZFRgTzBUYFT8VGBazFRgYJhUY",
        "GZkVGBsMFRgd8hUYH2UVGCDYFRgjvhUYJTEVGNtEFovctxaL3ioWi9+dFovhEBaL4oMWi+P2FovlaRaL5twWi+hQFovpwxaL",
        "6zYWi+ypFovuHBaL748Wi/ECFovydRaL8+gWi/VbFov2zhaL+EIWi/m1Fov8mxaL/g4Wi/+BFosA9BaLAmcWiwPaFosFTRaL",
        "BsEWiwg0FosJpxaLCxoWiwyNFosOABaLD3MWixDmFosSWRaLE8wWixU/FosWsxaLGCYWixmZFoscfxaLHfIWix9lFosg2BaL",
        "I74WiyUxFovbRBf/3ioX/9+dF//hEBf/4oMX/+P2F//m3Bf/6FAX/+nDF//rNhf/7KkX/+4cF//vjxf/8QIX//J1F//z6Bf/",
        "9VsX//bOF//4Qhf/+bUX//soF//8mxf//g4X//+BF/8A9Bf/AmcX/wPaF/8FTRf/BsEX/wg0F/8Jpxf/CxoX/wyNF/8OABf/",
        "D3MX/xDmF/8SWRf/E8wX/xU/F/8Wsxf/GCYX/xmZF/8bDBf/HH8X/x3yF/8fZRf/INgX/yO+F/8lMRf/3LcZcuVpGXLm3Bly",
        "6FAZcunDGXLrNhly7KkZcu4cGXLvjxly8QIZcvJ1GXLz6Bly9VsZcvbOGXL4Qhly+bUZcvsoGXL/gRlyAPQZcgJnGXID2hly",
        "BU0ZcgbBGXIINBlyCacZcgsaGXIMjRlyDgAZcg9zGXIQ5hlyElkZchPMGXIVPxlyFrMZchgmGXIZmRlyGwwZchx/GXId8hly",
        "H2UZciO+GXIlMRly3Lca5d4qGuXfnRrl4RAa5eKDGuXj9hrl5Wka5ebcGuXoUBrl6zYa5eypGuXuHBrl748a5fECGuXydRrl",
        "8+ga5fVbGuX2zhrl+EIa5fm1GuUA9BrlAmca5QPaGuUFTRrlBsEa5Qg0GuUJpxrlCxoa5QyNGuUOABrlD3Ma5RDmGuUSWRrl",
        "E8wa5RU/GuUWsxrlGCYa5RmZGuUbDBrlHH8a5R3yGuUfZRrlIksa5SO+GuXfnRxY4RAcWOKDHFjj9hxY5WkcWObcHFjoUBxY",
        "6cMcWOs2HFjsqRxY7hwcWO+PHFjxAhxY8nUcWPPoHFj1WxxY9s4cWAPaHFgFTRxYBsEcWAg0HFgJpxxYCxocWAyNHFgOABxY",
        "D3McWBDmHFgSWRxYE8wcWBU/HFgWsxxYGCYcWBmZHFgbDBxYHH8cWB3yHFgfZRxYIkscWCO+HFjigx3L4/Ydy+VpHcvpwx3L",
        "6zYdy+ypHcvuHB3L748dy/ECHcvydR3L8+gdy/VbHcv2zh3L+EIdywJnHcsD2h3LBU0dywbBHcsINB3LCxodywyNHcsOAB3L",
        "D3MdyxDmHcsSWR3LFT8dyxazHcsYJh3LGZkdyxsMHcscfx3LHfIdyyDYHcsiSx3L4oMfPuP2Hz7oUB8+6cMfPus2Hz7sqR8+",
        "7hwfPu+PHz7xAh8+8nUfPvPoHz71Wx8+9s4fPvhCHz4A9B8+AmcfPgVNHz4INB8+CacfPhU/Hz4YJh8+GZkfPhsMHz4cfx8+",
        "H2UfPiDYHz7j9iCx5WkgsebcILHoUCCx6cMgseypILHuHCCx748gsfECILHydSCx8+ggsfVbILH2ziCx+EIgsfm1ILH+DiCx",
        "/4EgsQbBILEINCCxFrMgsRmZILEbDCCxHH8gsR3yILEfZSCx5WkiJObcIiToUCIk7KkiJO4cIiTvjyIk8QIiJPJ1IiTz6CIk",
        "9VsiJPbOIiT4QiIk+bUiJPsoIiT8myIk/g4iJAJnIiQFTSIkBsEiJBgmIiQbDCIkHH8iJB3yIiTrNiOX7Kkjl+4cI5fvjyOX",
        "8QIjl/J1I5fz6COX9Vsjl/bOI5f5tSOXA9ojlwVNI5cZmSOXGwwjl+s2JQrsqSUK7hwlCu+PJQrxAiUK8nUlCvPoJQr1WyUK",
        "+EIlCgPaJQoZmSUKGwwlCunDJn7rNiZ+7Kkmfu4cJn7vjyZ+8QImfvVbJn72ziZ++EImfv+BJn4D2iZ+"
    ].joined()

    // Generated from /Users/albertonunez/Downloads/favicon.svg at 1024px,
    // sampling only the foreground Factory mark, not the black circular tile.
    private static let factoryPacked = [
        "8OHaiPIa2ojzU9qIDQvaiA5E2ogPftqI76fbwfDh28HyGtvB81PbwfSN28EIJdvBCV7bwQqY28EL0dvBDQvbwQ5E28EPftvB",
        "ELfbwRHw28Hubtz676fc+vDh3PryGtz681Pc+vSN3Pr1xtz6BbLc+gbr3PoIJdz6CV7c+gqY3PoL0dz6DQvc+g5E3PoPftz6",
        "ELfc+hHw3PrtNN407m7eNO+n3jTw4d408hreNPNT3jT0jd409cbeNAM/3jQEeN40BbLeNAbr3jQIJd40CV7eNAqY3jQL0d40",
        "DQveNA5E3jQPft40ELfeNBHw3jTtNN9t7m7fbe+n323w4d9t8hrfbfNT3230jd9t9cbfbfcA320AzN9tAgXfbQM/320EeN9t",
        "BbLfbQbr320IJd9tCV7fbQqY320L0d9tDQvfbQ5E320Pft9tELffbRHw323r++Cn7TTgp+5u4Kfvp+Cn8OHgp/Ia4KfzU+Cn",
        "9I3gp/XG4Kf3AOCn/lngp/+S4KcAzOCnAgXgpwM/4KcEeOCnBbLgpwbr4KcIJeCnCV7gpwqY4KcL0eCnDQvgpw5E4KcPfuCn",
        "ELfgpxHw4Kfr++Hg7TTh4O5u4eDvp+Hg8OHh4PIa4eDzU+Hg9I3h4PXG4eD3AOHg+Dnh4Pvm4eD9H+Hg/lnh4P+S4eAAzOHg",
        "AgXh4AvR4eANC+HgDkTh4A9+4eAQt+Hg6sHjGuv74xrtNOMa7m7jGu+n4xrw4eMa8hrjGvNT4xr0jeMa9cbjGvcA4xr4OeMa",
        "+XPjGvqs4xr75uMa/R/jGv5Z4xr/kuMaC9HjGg0L4xoOROMaD37jGhC34xrqweRT6/vkU+005FPubuRT81PkU/SN5FP1xuRT",
        "9wDkU/g55FP5c+RT+qzkU/vm5FP9H+RTCpjkUwvR5FMNC+RTDkTkUw9+5FMQt+RT6YjljerB5Y3r++WN7TTljfSN5Y31xuWN",
        "9wDljfg55Y35c+WN+qzljQqY5Y0L0eWNDQvljQ5E5Y0PfuWN6YjmxurB5sbr++bG7TTmxvSN5sb1xubG9wDmxvg55sb5c+bG",
        "CpjmxgvR5sYNC+bGDkTmxg9+5sbpiOgA6sHoAOv76AD1xugA9wDoAPg56AD5c+gA+qzoAAle6AAKmOgAC9HoAA0L6AAOROgA",
        "D37oABC36AAR8OgAEyroABRj6ADoTuk56YjpOerB6Tnr++k59cbpOfcA6Tn4Oek5+XPpOfqs6TkJXuk5CpjpOQvR6TkNC+k5",
        "DkTpOQ9+6TkQt+k5EfDpORMq6TkUY+k5FZ3pORbW6TkYEOk56E7qc+mI6nPqwepz9wDqc/g56nP5c+pz+qzqcwle6nMKmOpz",
        "C9Hqcw0L6nMR8OpzEyrqcxRj6nMVnepzFtbqcxgQ6nMZSepzGoPqcxu86nPoTuus6YjrrOrB66z3AOus+DnrrPlz66z6rOus",
        "++brrAgl66wJXuusCpjrrAvR66wNC+usFZ3rrBbW66wYEOusGUnrrBqD66wbvOusHPbrrB4v66wfaeus6E7s5umI7Ob4Oezm",
        "+XPs5vqs7Ob75uzmCCXs5gle7OYKmOzmC9Hs5hgQ7OYZSezmGoPs5hu87OYc9uzmHi/s5h9p7OYgouzmIdzs5twP7h/dSe4f",
        "3oLuH+cV7h/oTu4f6YjuH/g57h/5c+4f+qzuH/vm7h8G6+4fCCXuHwle7h8KmO4fC9HuHxqD7h8bvO4fHPbuHx4v7h8fae4f",
        "IKLuHyHc7h8jFe4f2tbvWdwP71ndSe9Z3oLvWd+871ng9e9Z4i/vWecV71noTu9Z6YjvWfg571n5c+9Z+qzvWfvm71n9H+9Z",
        "BuvvWQgl71kJXu9ZCpjvWRz271keL+9ZH2nvWSCi71kh3O9ZIxXvWSRP71nZnPCS2tbwktwP8JLdSfCS3oLwkt+88JLg9fCS",
        "4i/wkuNo8JLkovCS5dvwkucV8JLoTvCS+XPwkvqs8JL75vCS/R/wkgbr8JIIJfCSCV7wkgqY8JIeL/CSH2nwkiCi8JIh3PCS",
        "IxXwkiRP8JIliPCS2ZzxzNrW8czcD/HM3UnxzN6C8czfvPHM4PXxzOIv8czjaPHM5KLxzOXb8cznFfHM6E7xzPlz8cz6rPHM",
        "++bxzP0f8cwFsvHMBuvxzAgl8cwJXvHMHi/xzB9p8cwgovHMIdzxzCMV8cwkT/HMJYjxzCbC8czZnPMF2tbzBdwP8wXdSfMF",
        "3oLzBd+88wXg9fMF4i/zBeNo8wXkovMF5dvzBecV8wXoTvMF6YjzBerB8wX6rPMF++bzBf0f8wUFsvMFBuvzBQgl8wUJXvMF",
        "HPbzBR4v8wUfafMFIKLzBSHc8wUjFfMFJE/zBSWI8wUmwvMF2tb0P9wP9D/dSfQ/3oL0P9+89D/g9fQ/4i/0P+No9D/kovQ/",
        "5dv0P+cV9D/oTvQ/6Yj0P+rB9D/r+/Q/7TT0P/qs9D/75vQ//R/0P/5Z9D8EePQ/BbL0Pwbr9D8IJfQ/GoP0Pxu89D8c9vQ/",
        "Hi/0Px9p9D8govQ/Idz0PyMV9D8kT/Q/JYj0P9rW9XjcD/V43Un1eN6C9XjfvPV44PX1eOIv9XjjaPV45KL1eOXb9XjnFfV4",
        "6E71eOmI9XjqwfV46/v1eO009XjubvV476f1ePvm9Xj9H/V4/ln1eAR49XgFsvV4Buv1eAgl9XgYEPV4GUn1eBqD9XgbvPV4",
        "HPb1eB4v9XgfafV4IKL1eCHc9XgjFfV4JE/1eNrW9rLcD/ay3Un2st6C9rLfvPay5xX2suhO9rLpiPay6sH2suv79rLtNPay",
        "7m72su+n9rLw4fay8hr2svvm9rL9H/ay/ln2sgM/9rIEePayBbL2sgbr9rIVnfayFtb2shgQ9rIZSfayGoP2shu89rIc9vay",
        "Hi/2sh9p9rIgovayIdz2strW9+vcD/fr3Un3696C9+vfvPfr6sH36+v79+vtNPfr7m736++n9+vw4ffr8hr36/NT9+v0jffr",
        "++b36/0f9+v+Wffr/5L36wM/9+sEePfrBbL36xMq9+sUY/frFZ336xbW9+sYEPfrGUn36xqD9+sbvPfrHPb36x4v9+sfaffr",
        "3A/5Jd1J+SXegvkl37z5Je5u+SXvp/kl8OH5JfIa+SXzU/kl9I35JfXG+SX3APkl/R/5Jf5Z+SX/kvklAgX5JQM/+SUEePkl",
        "BbL5JQ9++SUQt/klEfD5JRMq+SUUY/klFZ35JRbW+SUYEPklGUn5JRqD+SUbvPklHPb5JdwP+l7dSfpe3oL6Xt+8+l7w4fpe",
        "8hr6XvNT+l70jfpe9cb6XvcA+l74Ofpe+XP6Xv0f+l7+Wfpe/5L6XgDM+l4CBfpeAz/6XgR4+l4NC/peDkT6Xg9++l4Qt/pe",
        "EfD6XhMq+l4UY/peFZ36XhbW+l4YEPpeGUn6XhqD+l4bvPpeHPb6Xh4v+l7dSfuX3oL7l9+8+5fzU/uX9I37l/XG+5f3APuX",
        "+Dn7l/lz+5f6rPuX++b7l/0f+5f+WfuX/5L7lwDM+5cCBfuXAz/7lwR4+5cJXvuXCpj7lwvR+5cNC/uXDkT7lw9++5cQt/uX",
        "EfD7lxMq+5cUY/uXFZ37lxu8+5cc9vuXHi/7l91J/NHegvzR37z80eD1/NH3APzR+Dn80flz/NH6rPzR++b80f0f/NH+WfzR",
        "/5L80QDM/NECBfzRAz/80QR4/NEFsvzRBuv80Qgl/NEJXvzRCpj80QvR/NENC/zRDkT80Q9+/NEQt/zREfD80Rz2/NEeL/zR",
        "H2n80d6C/grfvP4K4PX+Cvlz/gr6rP4K++b+Cv0f/gr+Wf4K/5L+CgDM/goCBf4KAz/+CgR4/goFsv4KBuv+Cggl/goJXv4K",
        "Cpj+CgvR/goNC/4KDkT+Chz2/goeL/4KH2n+Ct6C/0TfvP9E4PX/RPqs/0T75v9E/R//RP5Z/0T/kv9EAMz/RAIF/0QDP/9E",
        "BHj/RAWy/0QG6/9ECCX/RAle/0QeL/9EH2n/RCCi/0TfvAB94PUAfeIvAH34OQB9+XMAffqsAH375gB9/R8Aff5ZAH3/kgB9",
        "AMwAfQIFAH0DPwB9BHgAfQWyAH0eLwB9H2kAfSCiAH3fvAG34PUBt+IvAbfzUwG39I0Bt/XGAbf3AAG3+DkBt/lzAbf6rAG3",
        "++YBt/0fAbf+WQG3/5IBtwDMAbcCBQG3Az8BtwR4AbcFsgG3H2kBtyCiAbch3AG34PUC8OIvAvDjaALw7m4C8O+nAvDw4QLw",
        "8hoC8PNTAvD0jQLw9cYC8PcAAvD4OQLw+XMC8PqsAvD75gLw/R8C8P5ZAvD/kgLwAMwC8AIFAvADPwLwBHgC8AWyAvAG6wLw",
        "CCUC8AleAvAfaQLwIKIC8CHcAvDg9QQq4i8EKuNoBCrqwQQq6/sEKu00BCrubgQq76cEKvDhBCryGgQq81MEKvSNBCr1xgQq",
        "9wAEKvvmBCr9HwQq/lkEKv+SBCoAzAQqAgUEKgM/BCoEeAQqBbIEKgbrBCoIJQQqCV4EKgqYBCoL0QQqH2kEKiCiBCoh3AQq",
        "IxUEKuIvBWPjaAVj5KIFY+cVBWPoTgVj6YgFY+rBBWPr+wVj7TQFY+5uBWPvpwVj8OEFY/IaBWPzUwVj9I0FY/qsBWP75gVj",
        "/R8FY/5ZBWP/kgVjAMwFYwIFBWMDPwVjBusFYwglBWMJXgVjCpgFYwvRBWMNCwVjDkQFYyCiBWMh3AVjIxUFY+IvBp3jaAad",
        "5KIGneXbBp3nFQad6E4GnemIBp3qwQad6/sGne00Bp3ubgad76cGnfDhBp36rAad++YGnf0fBp0AzAadAgUGnQM/Bp0IJQad",
        "CV4GnQqYBp0L0QadDQsGnQ5EBp0PfgadELcGnRHwBp0gogadIdwGnSMVBp0kTwad4PUH1uIvB9bjaAfW5KIH1uXbB9bnFQfW",
        "6E4H1umIB9bqwQfW6/sH1u00B9b5cwfW+qwH1vvmB9b9HwfWAMwH1gIFB9YDPwfWCpgH1gvRB9YNCwfWDkQH1g9+B9YQtwfW",
        "EfAH1hMqB9YUYwfWIKIH1iHcB9YjFQfWJE8H1t6CCRDfvAkQ4PUJEOIvCRDjaAkQ5KIJEOXbCRDnFQkQ6E4JEOmICRDqwQkQ",
        "+XMJEPqsCRD75gkQAMwJEAIFCRADPwkQBHgJEA0LCRAORAkQD34JEBC3CRAR8AkQEyoJEBRjCRAVnQkQFtYJEBgQCRAgogkQ",
        "IdwJECMVCRAkTwkQJYgJENwPCkndSQpJ3oIKSd+8Ckng9QpJ4i8KSeNoCknkogpJ5dsKSecVCknoTgpJ+DkKSflzCkn6rApJ",
        "++YKSQIFCkkDPwpJBHgKSQ9+CkkQtwpJEfAKSRMqCkkUYwpJFZ0KSRbWCkkYEApJGUkKSRqDCkkbvApJH2kKSSCiCkkh3ApJ",
        "IxUKSSRPCkkliApJ2tYLg9wPC4PdSQuD3oILg9+8C4Pg9QuD4i8Lg+NoC4PkoguD5dsLg/g5C4P5cwuD+qwLg/vmC4MCBQuD",
        "Az8LgwR4C4MR8AuDEyoLgxRjC4MVnQuDFtYLgxgQC4MZSQuDGoMLgxu8C4Mc9guDHi8Lgx9pC4MgoguDIdwLgyMVC4MkTwuD",
        "JYgLg9mcDLza1gy83A8MvN1JDLzeggy837wMvOD1DLziLwy842gMvPcADLz4OQy8+XMMvPqsDLwCBQy8Az8MvAR4DLwFsgy8",
        "FGMMvBWdDLwW1gy8GBAMvBlJDLwagwy8G7wMvBz2DLweLwy8H2kMvCCiDLwh3Ay8IxUMvCRPDLwliAy82ZwN9trWDfbcDw32",
        "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"
    ].joined()
}
