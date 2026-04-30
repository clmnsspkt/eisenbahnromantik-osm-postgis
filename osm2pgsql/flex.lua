local schema = os.getenv('OSM_IMPORT_SCHEMA') or 'osm_import'

local admin_boundary = osm2pgsql.define_area_table('admin_boundary', {
    { column = 'osm_id', type = 'bigint' },
    { column = 'name', type = 'text' },
    { column = 'admin_level', type = 'text' },
    { column = 'boundary', type = 'text' },
    { column = 'tags', type = 'hstore' },
    { column = 'geom', type = 'multipolygon' },
}, { schema = schema })

local railway_point = osm2pgsql.define_node_table('railway_point', {
    { column = 'osm_id', type = 'bigint' },
    { column = 'name', type = 'text' },
    { column = 'railway', type = 'text' },
    { column = 'tags', type = 'hstore' },
    { column = 'geom', type = 'point' },
}, { schema = schema })

local pt_stop_area = osm2pgsql.define_relation_table('pt_stop_area', {
    { column = 'osm_id', type = 'bigint' },
    { column = 'name', type = 'text' },
    { column = 'public_transport', type = 'text' },
    { column = 'relation_type', type = 'text' },
    { column = 'tags', type = 'hstore' },
}, { schema = schema })

local pt_stop_area_member = osm2pgsql.define_relation_table('pt_stop_area_member', {
    { column = 'osm_id', type = 'bigint' },
    { column = 'stop_area_osm_id', type = 'bigint' },
    { column = 'member_seq', type = 'int' },
    { column = 'member_type', type = 'text' },
    { column = 'member_osm_id', type = 'bigint' },
    { column = 'member_role', type = 'text' },
}, { schema = schema })

local function is_admin_boundary(tags)
    if tags.boundary ~= 'administrative' then
        return false
    end
    local level = tags.admin_level
    return level == '2' or level == '4' or level == '6'
end

local function is_railway_candidate(tags)
    local railway = tags.railway
    local public_transport = tags.public_transport

    if railway == 'halt' or railway == 'stop' or railway == 'station' or railway == 'platform' then
        return true
    end

    if public_transport == 'station' or public_transport == 'stop_position' or public_transport == 'platform' then
        return true
    end

    return false
end

local function is_stop_area_relation(tags)
    if tags.type ~= 'public_transport' then
        return false
    end
    local pt = tags.public_transport
    return pt == 'stop_area' or pt == 'stop_area_group'
end

function osm2pgsql.process_relation(object)
    if is_admin_boundary(object.tags) then
        local geom = object:as_multipolygon()
        if not geom then
            return
        end
        admin_boundary:insert({
            osm_id = object.id,
            name = object.tags.name,
            admin_level = object.tags.admin_level,
            boundary = object.tags.boundary,
            tags = object.tags,
            geom = geom,
        })
    end

    if is_stop_area_relation(object.tags) then
        pt_stop_area:insert({
            osm_id = object.id,
            name = object.tags.name,
            public_transport = object.tags.public_transport,
            relation_type = object.tags.type,
            tags = object.tags,
        })

        if object.members then
            for idx, member in ipairs(object.members) do
                if member and member.ref then
                    local mtype = member.type
                    if mtype == 'n' or mtype == 'w' or mtype == 'r' then
                        pt_stop_area_member:insert({
                            osm_id = object.id,
                            stop_area_osm_id = object.id,
                            member_seq = idx,
                            member_type = mtype,
                            member_osm_id = member.ref,
                            member_role = member.role or '',
                        })
                    end
                end
            end
        end
    end
end

function osm2pgsql.process_way(object)
    if is_admin_boundary(object.tags) then
        local geom = object:as_multipolygon()
        if not geom then
            return
        end
        admin_boundary:insert({
            osm_id = object.id,
            name = object.tags.name,
            admin_level = object.tags.admin_level,
            boundary = object.tags.boundary,
            tags = object.tags,
            geom = geom,
        })
    end
end

function osm2pgsql.process_node(object)
    if is_railway_candidate(object.tags) then
        railway_point:insert({
            osm_id = object.id,
            name = object.tags.name,
            railway = object.tags.railway,
            tags = object.tags,
            geom = object:as_point(),
        })
    end
end
